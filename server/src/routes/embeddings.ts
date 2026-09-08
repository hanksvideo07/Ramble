import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool, toVectorLiteral } from '../db/pool.ts';
import { config } from '../lib/config.ts';
import { HttpError, requireUser } from '../lib/auth.ts';
import { log } from '../lib/logger.ts';
import { activeEmbeddingSpace } from '../providers/embedding.ts';

/**
 * Embeddings produced on the device.
 *
 * The server decides *what* gets embedded — it owns chunking, so there is one
 * definition of a searchable unit rather than two that can drift — and the
 * device does the embedding. It works like the pending-actions queue: the
 * client asks what is outstanding, does the work, and posts results back.
 */
export async function embeddingRoutes(app: FastifyInstance): Promise<void> {
  /** Units this user has that still have no vector. */
  app.get('/v1/embeddings/pending', async (request) => {
    const user = await requireUser(request);
    const query = z
      .object({ limit: z.coerce.number().min(1).max(200).default(50) })
      .parse(request.query);

    const { rows } = await pool.query<{ id: string; content: string }>(
      `SELECT id, content
         FROM embedding_records
        WHERE user_id = $1 AND embedding IS NULL
        ORDER BY created_at
        LIMIT $2`,
      [user.id, query.limit],
    );

    const space = activeEmbeddingSpace();
    return {
      // Nothing for the device to do when the server owns embedding; handing
      // it work it must not complete would just waste the phone's battery.
      units: space.serverEmbeds ? [] : rows,
      dimension: space.dimension,
      // Vectors are only comparable within one model revision, so the client
      // is told which one this corpus is built from.
      expected_revision: space.revision,
      // Lets the app say why it has nothing to do, rather than looking broken.
      server_embeds: space.serverEmbeds,
    };
  });

  /** Stores vectors the device computed. */
  app.post('/v1/embeddings', async (request) => {
    const user = await requireUser(request);
    const body = z
      .object({
        revision: z.number().int().min(0),
        vectors: z
          .array(z.object({ id: z.string().uuid(), vector: z.array(z.number()) }))
          .min(1)
          .max(200),
      })
      .parse(request.body);

    const space = activeEmbeddingSpace();

    // The server owning embedding is the whole reason to refuse here. Both
    // models produce vectors of the same width, so a stale client posting
    // Apple vectors into an OpenAI corpus would be accepted by a width check
    // and would quietly poison every future search.
    if (space.serverEmbeds) {
      throw new HttpError(
        409,
        'This account is embedded on the server. Device vectors are not accepted.',
      );
    }

    // A width mismatch means a different model, not a smaller payload. Storing
    // it would corrupt every future search, so it is rejected outright.
    const wrongWidth = body.vectors.find((v) => v.vector.length !== space.dimension);
    if (wrongWidth) {
      throw new HttpError(
        400,
        `Expected ${space.dimension}-dimensional vectors, got ${wrongWidth.vector.length}.`,
      );
    }

    // A device on an older build embeds into a space this corpus has moved on
    // from. Its vectors are valid, just not comparable to anything here.
    if (body.revision !== space.revision) {
      throw new HttpError(
        409,
        `These vectors are from revision ${body.revision}; this account is on ${space.revision}.`,
      );
    }

    let stored = 0;
    for (const entry of body.vectors) {
      // Scoped by user_id as well as id: a vector may only ever be written
      // into a row its sender owns.
      const { rowCount } = await pool.query(
        `UPDATE embedding_records
            SET embedding = $3::vector, model_revision = $4, model = $5
          WHERE id = $1 AND user_id = $2`,
        [entry.id, user.id, toVectorLiteral(entry.vector), body.revision, space.model],
      );
      stored += rowCount ?? 0;
    }

    log.info('embeddings.stored', { user_id: user.id, count: stored, revision: body.revision });
    return { stored };
  });

  /**
   * Reports the device's embedding model.
   *
   * If the revision has moved on, every stored vector was produced by a
   * different model and is no longer comparable. Rather than let search quietly
   * degrade, the affected vectors are cleared so the device re-embeds them.
   */
  app.post('/v1/embeddings/handshake', async (request) => {
    const user = await requireUser(request);
    const body = z
      .object({ dimension: z.number().int().positive(), revision: z.number().int().min(0) })
      .parse(request.body);

    if (body.dimension !== config.embedding.dimension) {
      throw new HttpError(
        409,
        `This server stores ${config.embedding.dimension}-dimensional vectors; ` +
          `your device produces ${body.dimension}. Semantic search is unavailable until they match.`,
      );
    }

    const { rows: current } = await pool.query<{ revision: number | null }>(
      `SELECT MAX(model_revision) AS revision
         FROM embedding_records
        WHERE user_id = $1 AND embedding IS NOT NULL`,
      [user.id],
    );
    const stored = current[0]?.revision ?? null;

    if (stored !== null && stored !== body.revision) {
      const { rowCount } = await pool.query(
        `UPDATE embedding_records
            SET embedding = NULL
          WHERE user_id = $1 AND model_revision <> $2`,
        [user.id, body.revision],
      );
      log.warn('embeddings.revision_changed', {
        user_id: user.id,
        from: stored,
        to: body.revision,
        invalidated: rowCount ?? 0,
      });
      return { ok: true, reindexing: rowCount ?? 0 };
    }

    return { ok: true, reindexing: 0 };
  });
}
