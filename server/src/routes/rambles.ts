import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool, withTransaction } from '../db/pool.ts';
import { HttpError, requireUser } from '../lib/auth.ts';
import { track } from '../lib/analytics.ts';
import { log } from '../lib/logger.ts';
import { audioKey, putAudio, signedPlaybackUrl } from '../lib/storage.ts';
import { emitWebhook } from '../integrations/webhooks.ts';
import { enqueue } from '../pipeline/queue.ts';
import { mergeEntities } from '../pipeline/entities.ts';

export async function rambleRoutes(app: FastifyInstance): Promise<void> {
  /**
   * Registers a capture. The device calls this immediately on stop — before
   * the audio finishes uploading — so an offline recording still has a real
   * row and a place in the timeline. client_id makes retries idempotent.
   */
  app.post('/v1/rambles', async (request, reply) => {
    const user = await requireUser(request);
    const body = z
      .object({
        client_id: z.string().min(1).max(120),
        recorded_at: z.string(),
        duration_seconds: z.number().min(0),
        source_device: z.enum(['ios', 'watch', 'action_button', 'widget', 'import']).default('ios'),
        location: z.object({ latitude: z.number(), longitude: z.number() }).nullish(),
      })
      .parse(request.body);

    const { rows } = await pool.query<{ id: string; processing_state: string; created: boolean }>(
      `INSERT INTO rambles (user_id, client_id, recorded_at, duration_seconds, source_device, location)
       VALUES ($1,$2,$3,$4,$5,$6::jsonb)
       ON CONFLICT (user_id, client_id) DO UPDATE
         SET duration_seconds = EXCLUDED.duration_seconds
       RETURNING id, processing_state, (xmax = 0) AS created`,
      [
        user.id,
        body.client_id,
        body.recorded_at,
        body.duration_seconds,
        body.source_device,
        body.location ? JSON.stringify(body.location) : null,
      ],
    );
    const ramble = rows[0]!;

    if (ramble.created) {
      await track(user.id, 'ramble_created', {
        source_device: body.source_device,
        duration_seconds: Math.round(body.duration_seconds),
      });
      await emitWebhook(user.id, 'ramble.created', { ramble_id: ramble.id });
    }

    return reply.code(ramble.created ? 201 : 200).send({
      id: ramble.id,
      processing_state: ramble.processing_state,
    });
  });

  /**
   * Uploads the audio and starts processing. Separate from creation so a
   * device that recorded offline can upload later without losing its place.
   */
  app.post('/v1/rambles/:id/audio', async (request, reply) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);

    const owned = await pool.query<{ id: string }>(
      `SELECT id FROM rambles WHERE id = $1 AND user_id = $2`,
      [id, user.id],
    );
    if (owned.rowCount === 0) throw new HttpError(404, 'Ramble not found.');

    const file = await request.file();
    if (!file) throw new HttpError(400, 'Expected an audio file in the request body.');
    const buffer = await file.toBuffer();
    if (buffer.length === 0) throw new HttpError(400, 'Audio file was empty.');

    const contentType = file.mimetype || 'audio/m4a';
    const extension = contentType.includes('wav') ? 'wav' : 'm4a';
    const key = audioKey(user.id, id, extension);

    try {
      await putAudio(key, buffer, contentType);
    } catch (error) {
      log.error('upload.failed', { ramble_id: id, error: String(error) });
      await track(user.id, 'upload_failed', { ramble_id: id });
      throw new HttpError(502, 'Could not store the audio. The recording is safe on your device; try again.');
    }

    await withTransaction(async (client) => {
      await client.query(`DELETE FROM audio_assets WHERE ramble_id = $1`, [id]);
      await client.query(
        `INSERT INTO audio_assets (ramble_id, user_id, storage_key, content_type, byte_size)
         VALUES ($1,$2,$3,$4,$5)`,
        [id, user.id, key, contentType, buffer.length],
      );
      await client.query(
        `UPDATE rambles SET processing_state = 'uploaded', processing_error = NULL WHERE id = $1`,
        [id],
      );
    });

    await track(user.id, 'upload_succeeded', { ramble_id: id, bytes: buffer.length });
    enqueue(id);
    return reply.code(202).send({ id, processing_state: 'uploaded' });
  });

  /** The timeline. Cursor-paginated by recorded_at. */
  app.get('/v1/rambles', async (request) => {
    const user = await requireUser(request);
    const query = z
      .object({
        limit: z.coerce.number().min(1).max(100).default(30),
        before: z.string().optional(),
      })
      .parse(request.query);

    const params: unknown[] = [user.id];
    let cursor = '';
    if (query.before) {
      params.push(query.before);
      cursor = `AND r.recorded_at < $${params.length}`;
    }
    params.push(query.limit);

    const { rows } = await pool.query(
      `SELECT r.id, r.title, r.summary, r.recorded_at, r.duration_seconds,
              r.processing_state, r.source_device,
              COALESCE(counts.items, '{}'::jsonb) AS item_counts,
              COALESCE(ents.names, '{}'::text[]) AS entity_names,
              COALESCE(acts.pending, 0) AS pending_actions
         FROM rambles r
         LEFT JOIN LATERAL (
           SELECT jsonb_object_agg(kind, n) AS items
             FROM (SELECT kind, COUNT(*) AS n FROM extracted_items
                    WHERE ramble_id = r.id AND status <> 'dismissed'
                    GROUP BY kind) k
         ) counts ON true
         LEFT JOIN LATERAL (
           SELECT array_agg(DISTINCT e.name) AS names
             FROM entity_mentions m JOIN entities e ON e.id = m.entity_id
            WHERE m.ramble_id = r.id AND e.merged_into_id IS NULL
         ) ents ON true
         LEFT JOIN LATERAL (
           SELECT COUNT(*) AS pending FROM actions
            WHERE ramble_id = r.id AND state = 'awaiting_confirmation'
         ) acts ON true
        WHERE r.user_id = $1 ${cursor}
        ORDER BY r.recorded_at DESC
        LIMIT $${params.length}`,
      params,
    );

    return {
      rambles: rows.map(serializeCard),
      next_cursor: rows.length === query.limit ? rows[rows.length - 1]?.recorded_at : null,
    };
  });

  /** Full detail: transcript, items, entities, actions, related rambles. */
  app.get('/v1/rambles/:id', async (request) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);

    const { rows: rambleRows } = await pool.query(
      `SELECT id, title, summary, clean_transcript, recorded_at, duration_seconds,
              processing_state, processing_error, source_device, language
         FROM rambles WHERE id = $1 AND user_id = $2`,
      [id, user.id],
    );
    const ramble = rambleRows[0];
    if (!ramble) throw new HttpError(404, 'Ramble not found.');

    const [transcript, items, entities, actions, audio, related] = await Promise.all([
      pool.query(
        `SELECT s.idx, s.start_seconds, s.end_seconds, s.text
           FROM transcript_segments s
           JOIN transcripts t ON t.id = s.transcript_id
          WHERE s.ramble_id = $1 ORDER BY t.created_at DESC, s.idx`,
        [id],
      ),
      pool.query(
        `SELECT id, kind, title, body, attributes, status, confidence,
                source_start_seconds, source_quote, corrected_by_user
           FROM extracted_items
          WHERE ramble_id = $1 AND user_id = $2 AND status <> 'dismissed'
          ORDER BY kind, created_at`,
        [id, user.id],
      ),
      pool.query(
        `SELECT DISTINCT e.id, e.kind, e.name
           FROM entity_mentions m JOIN entities e ON e.id = m.entity_id
          WHERE m.ramble_id = $1 AND m.user_id = $2 AND e.merged_into_id IS NULL
          ORDER BY e.name`,
        [id, user.id],
      ),
      pool.query(
        `SELECT id, type, parameters, state, confidence, intent_class, risk,
                requires_confirmation, result, error, executed_at
           FROM actions WHERE ramble_id = $1 AND user_id = $2 ORDER BY created_at`,
        [id, user.id],
      ),
      pool.query<{ storage_key: string }>(
        `SELECT storage_key FROM audio_assets WHERE ramble_id = $1 LIMIT 1`,
        [id],
      ),
      // Related rambles: those sharing an entity with this one, most recent first.
      pool.query(
        `SELECT DISTINCT r.id, r.title, r.recorded_at
           FROM entity_mentions m1
           JOIN entity_mentions m2 ON m2.entity_id = m1.entity_id AND m2.ramble_id <> m1.ramble_id
           JOIN rambles r ON r.id = m2.ramble_id
          WHERE m1.ramble_id = $1 AND r.user_id = $2
          ORDER BY r.recorded_at DESC LIMIT 5`,
        [id, user.id],
      ),
    ]);

    const storageKey = audio.rows[0]?.storage_key;
    return {
      id: ramble.id,
      title: ramble.title,
      summary: ramble.summary,
      clean_transcript: ramble.clean_transcript,
      recorded_at: ramble.recorded_at,
      duration_seconds: ramble.duration_seconds,
      processing_state: ramble.processing_state,
      processing_error: ramble.processing_error,
      source_device: ramble.source_device,
      language: ramble.language,
      audio_url: storageKey ? await signedPlaybackUrl(storageKey) : null,
      segments: transcript.rows.map((s) => ({
        index: s.idx,
        start_seconds: s.start_seconds,
        end_seconds: s.end_seconds,
        text: s.text,
      })),
      items: items.rows,
      entities: entities.rows,
      actions: actions.rows,
      related: related.rows,
    };
  });

  app.delete('/v1/rambles/:id', async (request, reply) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const { rowCount } = await pool.query(`DELETE FROM rambles WHERE id = $1 AND user_id = $2`, [
      id,
      user.id,
    ]);
    if (rowCount === 0) throw new HttpError(404, 'Ramble not found.');
    return reply.code(204).send();
  });

  /** Re-runs processing from the earliest failed stage. */
  app.post('/v1/rambles/:id/reprocess', async (request, reply) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const { rowCount } = await pool.query(
      `UPDATE rambles SET processing_state = 'uploaded', processing_error = NULL
        WHERE id = $1 AND user_id = $2`,
      [id, user.id],
    );
    if (rowCount === 0) throw new HttpError(404, 'Ramble not found.');
    enqueue(id, { force: true });
    return reply.code(202).send({ id, processing_state: 'uploaded' });
  });

  // --- user corrections ----------------------------------------------------
  // Corrections are marked so re-processing never overwrites them, and so they
  // can later train personalization.

  app.patch('/v1/items/:id', async (request) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const body = z
      .object({
        kind: z
          .enum(['summary', 'note', 'idea', 'task', 'reminder', 'decision', 'question', 'journal', 'commitment', 'follow_up', 'reference'])
          .optional(),
        title: z.string().min(1).max(200).optional(),
        body: z.string().max(4000).nullish(),
        status: z.enum(['open', 'done', 'dismissed', 'archived']).optional(),
        attributes: z.record(z.unknown()).optional(),
      })
      .parse(request.body);

    const { rows } = await pool.query(
      `UPDATE extracted_items
          SET kind = COALESCE($3, kind),
              original_kind = CASE WHEN $3 IS NOT NULL AND original_kind IS NULL THEN kind ELSE original_kind END,
              title = COALESCE($4, title),
              body = COALESCE($5, body),
              status = COALESCE($6, status),
              attributes = CASE WHEN $7::jsonb IS NULL THEN attributes ELSE attributes || $7::jsonb END,
              corrected_by_user = true
        WHERE id = $1 AND user_id = $2
        RETURNING id, kind, title, body, status, attributes, corrected_by_user`,
      [
        id,
        user.id,
        body.kind ?? null,
        body.title ?? null,
        body.body ?? null,
        body.status ?? null,
        body.attributes ? JSON.stringify(body.attributes) : null,
      ],
    );
    const item = rows[0];
    if (!item) throw new HttpError(404, 'Item not found.');
    await track(user.id, 'item_corrected', { changed_kind: body.kind != null });
    return item;
  });

  /** "This ramble is about Nationwide." */
  app.post('/v1/rambles/:id/entities', async (request) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const body = z.object({ entity_id: z.string().uuid() }).parse(request.body);

    const check = await pool.query(
      `SELECT 1 FROM rambles r, entities e
        WHERE r.id = $1 AND r.user_id = $3 AND e.id = $2 AND e.user_id = $3`,
      [id, body.entity_id, user.id],
    );
    if (check.rowCount === 0) throw new HttpError(404, 'Ramble or entity not found.');

    await pool.query(
      `INSERT INTO entity_mentions (entity_id, user_id, ramble_id, mention_text, confidence)
       SELECT $1, $2, $3, e.name, 1.0 FROM entities e WHERE e.id = $1
       ON CONFLICT DO NOTHING`,
      [body.entity_id, user.id, id],
    );
    return { ok: true };
  });

  /** "Sarah Chen and Sarah are the same person." */
  app.post('/v1/entities/:id/merge', async (request) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const body = z.object({ into_entity_id: z.string().uuid() }).parse(request.body);

    await withTransaction((client) => mergeEntities(client, user.id, id, body.into_entity_id));
    await track(user.id, 'entities_merged', {});
    return { ok: true, merged_into: body.into_entity_id };
  });
}

function serializeCard(row: Record<string, unknown>) {
  return {
    id: row.id,
    title: row.title,
    summary: row.summary,
    recorded_at: row.recorded_at,
    duration_seconds: row.duration_seconds,
    processing_state: row.processing_state,
    source_device: row.source_device,
    item_counts: row.item_counts ?? {},
    entity_names: row.entity_names ?? [],
    pending_actions: Number(row.pending_actions ?? 0),
  };
}
