import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool } from '../db/pool.ts';
import { HttpError, requireUser } from '../lib/auth.ts';

export async function entityRoutes(app: FastifyInstance): Promise<void> {
  app.get('/v1/entities', async (request) => {
    const user = await requireUser(request);
    const query = z
      .object({
        q: z.string().optional(),
        kind: z.string().optional(),
        limit: z.coerce.number().min(1).max(100).default(50),
      })
      .parse(request.query);

    const params: unknown[] = [user.id];
    const clauses: string[] = [];
    if (query.q) {
      params.push(query.q.toLowerCase());
      clauses.push(`AND (normalized_name % $${params.length} OR normalized_name ILIKE '%' || $${params.length} || '%')`);
    }
    if (query.kind) {
      params.push(query.kind);
      clauses.push(`AND kind = $${params.length}`);
    }
    params.push(query.limit);

    const { rows } = await pool.query(
      `SELECT id, kind, name, aliases, mention_count, last_seen_at
         FROM entities
        WHERE user_id = $1 AND merged_into_id IS NULL ${clauses.join(' ')}
        ORDER BY mention_count DESC, last_seen_at DESC
        LIMIT $${params.length}`,
      params,
    );
    return { entities: rows };
  });

  /**
   * An entity page: what this person or company is, everything open involving
   * them, what was decided, who they connect to, and every ramble they appear
   * in. Assembled from memory on read, so it stays current with no rebuild.
   */
  app.get('/v1/entities/:id', async (request) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);

    const { rows: entityRows } = await pool.query(
      `SELECT id, kind, name, aliases, overview, mention_count, first_seen_at, last_seen_at
         FROM entities WHERE id = $1 AND user_id = $2 AND merged_into_id IS NULL`,
      [id, user.id],
    );
    const entity = entityRows[0];
    if (!entity) throw new HttpError(404, 'Entity not found.');

    const [activity, openItems, decisions, people, rambles] = await Promise.all([
      // Recent activity: one line per ramble this entity appeared in.
      pool.query(
        `SELECT r.id, r.title, r.summary, r.recorded_at
           FROM entity_mentions m JOIN rambles r ON r.id = m.ramble_id
          WHERE m.entity_id = $1 AND m.user_id = $2
          GROUP BY r.id ORDER BY r.recorded_at DESC LIMIT 20`,
        [id, user.id],
      ),
      pool.query(
        `SELECT DISTINCT i.id, i.kind, i.title, i.attributes, i.ramble_id
           FROM extracted_items i
           JOIN entity_mentions m ON m.ramble_id = i.ramble_id
          WHERE m.entity_id = $1 AND i.user_id = $2 AND i.status = 'open'
            AND i.kind IN ('task','reminder','commitment','follow_up')
          ORDER BY i.id LIMIT 20`,
        [id, user.id],
      ),
      pool.query(
        `SELECT DISTINCT i.id, i.title, i.body, i.ramble_id, i.created_at
           FROM extracted_items i
           JOIN entity_mentions m ON m.ramble_id = i.ramble_id
          WHERE m.entity_id = $1 AND i.user_id = $2 AND i.kind = 'decision'
          ORDER BY i.created_at DESC LIMIT 20`,
        [id, user.id],
      ),
      // Entities co-occurring with this one, most frequent first.
      pool.query(
        `SELECT e.id, e.kind, e.name, COUNT(*) AS shared
           FROM entity_mentions m1
           JOIN entity_mentions m2 ON m2.ramble_id = m1.ramble_id AND m2.entity_id <> m1.entity_id
           JOIN entities e ON e.id = m2.entity_id
          WHERE m1.entity_id = $1 AND m1.user_id = $2 AND e.merged_into_id IS NULL
          GROUP BY e.id ORDER BY shared DESC LIMIT 10`,
        [id, user.id],
      ),
      pool.query(
        `SELECT COUNT(DISTINCT ramble_id)::int AS n FROM entity_mentions
          WHERE entity_id = $1 AND user_id = $2`,
        [id, user.id],
      ),
    ]);

    return {
      ...entity,
      ramble_count: rambles.rows[0]?.n ?? 0,
      activity: activity.rows,
      open_items: openItems.rows,
      decisions: decisions.rows,
      related_entities: people.rows,
    };
  });

  app.patch('/v1/entities/:id', async (request) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const body = z
      .object({
        name: z.string().min(1).max(200).optional(),
        kind: z.enum(['person', 'organization', 'project', 'place', 'product', 'topic']).optional(),
        overview: z.string().max(4000).nullish(),
      })
      .parse(request.body);

    const { rows } = await pool.query(
      `UPDATE entities
          SET name = COALESCE($3, name), kind = COALESCE($4, kind), overview = COALESCE($5, overview)
        WHERE id = $1 AND user_id = $2
        RETURNING id, kind, name, aliases, overview`,
      [id, user.id, body.name ?? null, body.kind ?? null, body.overview ?? null],
    );
    const entity = rows[0];
    if (!entity) throw new HttpError(404, 'Entity not found.');
    return entity;
  });
}
