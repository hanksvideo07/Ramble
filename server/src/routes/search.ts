import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool } from '../db/pool.ts';
import { requireUser } from '../lib/auth.ts';
import { track } from '../lib/analytics.ts';
import { hybridSearch, inferKinds } from '../pipeline/search.ts';
import { createAnswerProvider } from '../providers/answer.ts';

const answerProvider = createAnswerProvider();

export async function searchRoutes(app: FastifyInstance): Promise<void> {
  /**
   * Search with a query vector embedded on the device.
   *
   * A POST rather than a GET because a 512-float vector does not belong in a
   * query string. The text is still sent: lexical and structured search need
   * the words, and the vector only drives the semantic third.
   */
  app.post('/v1/search', async (request) => {
    const user = await requireUser(request);
    const body = z
      .object({
        q: z.string().min(1).max(500),
        limit: z.number().min(1).max(50).default(20),
        kinds: z.array(z.string()).optional(),
        entity_id: z.string().uuid().optional(),
        vector: z.array(z.number()).optional(),
      })
      .parse(request.body);

    const hits = await hybridSearch(user.id, body.q, {
      limit: body.limit,
      kinds: body.kinds,
      entityId: body.entity_id,
      queryVector: body.vector,
    });

    await track(user.id, 'search_performed', {
      result_count: hits.length,
      semantic: body.vector != null,
    });
    return { query: body.q, hits };
  });

  app.get('/v1/search', async (request) => {
    const user = await requireUser(request);
    const query = z
      .object({
        q: z.string().min(1).max(500),
        limit: z.coerce.number().min(1).max(50).default(20),
        kinds: z.string().optional(),
        entity_id: z.string().uuid().optional(),
        since: z.string().optional(),
      })
      .parse(request.query);

    const hits = await hybridSearch(user.id, query.q, {
      limit: query.limit,
      kinds: query.kinds ? query.kinds.split(',') : undefined,
      entityId: query.entity_id,
      since: query.since ? new Date(query.since) : undefined,
    });

    await track(user.id, 'search_performed', { result_count: hits.length, has_filters: !!query.kinds });
    return { query: query.q, hits };
  });

  /**
   * Ask Ramble. Retrieval first, then synthesis strictly over what was
   * retrieved, with citations back to the source rambles.
   */
  app.post('/v1/ask', async (request) => {
    const user = await requireUser(request);
    const body = z
      .object({
        question: z.string().min(1).max(1000),
        vector: z.array(z.number()).optional(),
      })
      .parse(request.body);

    const hits = await hybridSearch(user.id, body.question, {
      limit: 12,
      kinds: inferKinds(body.question),
      queryVector: body.vector,
    });

    const result = await answerProvider.answer(
      body.question,
      hits.map((hit) => ({
        rambleId: hit.rambleId,
        rambleTitle: hit.rambleTitle ?? 'Untitled',
        recordedAt: hit.recordedAt,
        sourceKind: hit.sourceKind,
        content: hit.content,
      })),
    );

    await track(user.id, 'ask_performed', { retrieved: hits.length, mocked: result.mocked });
    return { question: body.question, ...result };
  });

  /**
   * A sense of what has accumulated.
   *
   * Nothing in the app conveyed that anything was building up — no idea how
   * much had been captured, who keeps coming up, or what the person keeps
   * returning to. That is the emotional core of a memory product and it was
   * entirely absent, so this is the data behind putting it back.
   *
   * Counts only. No content leaves here that the timeline would not show.
   */
  app.get('/v1/summary', async (request) => {
    const user = await requireUser(request);
    const [totals, kinds, people, streak] = await Promise.all([
      pool.query<{ rambles: string; seconds: string; first_at: Date | null }>(
        `SELECT COUNT(*)::text AS rambles,
                COALESCE(SUM(duration_seconds), 0)::text AS seconds,
                MIN(recorded_at) AS first_at
           FROM rambles WHERE user_id = $1`,
        [user.id],
      ),
      pool.query<{ kind: string; n: string }>(
        `SELECT kind, COUNT(*)::text AS n
           FROM extracted_items
          WHERE user_id = $1 AND kind <> 'summary'
          GROUP BY kind ORDER BY COUNT(*) DESC`,
        [user.id],
      ),
      // Who keeps coming up. Ordered by how often, not how recently — the
      // point is recurrence, which is what a person cannot see for themselves.
      pool.query<{ id: string; name: string; kind: string; mentions: number }>(
        `SELECT id, name, kind, mention_count AS mentions
           FROM entities
          WHERE user_id = $1 AND merged_into_id IS NULL AND mention_count > 1
          ORDER BY mention_count DESC, last_seen_at DESC
          LIMIT 6`,
        [user.id],
      ),
      // Consecutive days ending today or yesterday. Counting from yesterday
      // too, so a streak is not broken merely because it is early morning.
      pool.query<{ days: string }>(
        `WITH days AS (
           SELECT DISTINCT date_trunc('day', recorded_at)::date AS d
             FROM rambles WHERE user_id = $1
         ), ranked AS (
           SELECT d, d - (ROW_NUMBER() OVER (ORDER BY d))::int AS grp FROM days
         )
         SELECT COUNT(*)::text AS days FROM ranked
          WHERE grp = (SELECT grp FROM ranked ORDER BY d DESC LIMIT 1)
            AND (SELECT MAX(d) FROM days) >= CURRENT_DATE - 1`,
        [user.id],
      ),
    ]);

    const row = totals.rows[0]!;
    return {
      rambles: Number(row.rambles),
      total_seconds: Math.round(Number(row.seconds)),
      first_recorded_at: row.first_at,
      items_by_kind: Object.fromEntries(kinds.rows.map((r) => [r.kind, Number(r.n)])),
      recurring: people.rows,
      streak_days: Number(streak.rows[0]?.days ?? 0),
    };
  });

  /** Everything still open: the "needs you" set across all rambles. */
  app.get('/v1/inbox', async (request) => {
    const user = await requireUser(request);
    const [actions, tasks] = await Promise.all([
      // The source quote and its timestamp live on the extracted item the
      // action came from, and the confirmation card is not honest without
      // them: approving something you cannot trace back to your own words is
      // exactly what the guide forbids.
      pool.query(
        `SELECT a.id, a.type, a.parameters, a.confidence, a.intent_class, a.risk,
                a.state, a.ramble_id, r.title AS ramble_title, a.created_at,
                i.source_quote, i.source_start_seconds
           FROM actions a
           JOIN rambles r ON r.id = a.ramble_id
           LEFT JOIN extracted_items i ON i.id = a.extracted_item_id
          WHERE a.user_id = $1 AND a.state = 'awaiting_confirmation'
          ORDER BY a.created_at DESC LIMIT 50`,
        [user.id],
      ),
      pool.query(
        `SELECT i.id, i.kind, i.title, i.body, i.attributes, i.status, i.confidence,
                i.source_start_seconds, i.source_quote, i.corrected_by_user,
                i.ramble_id, r.title AS ramble_title, i.created_at
           FROM extracted_items i
           JOIN rambles r ON r.id = i.ramble_id
          WHERE i.user_id = $1 AND i.status = 'open'
            AND i.kind IN ('task','reminder','commitment','follow_up','question')
          ORDER BY (i.attributes->>'due_at') NULLS LAST, i.created_at DESC
          LIMIT 50`,
        [user.id],
      ),
    ]);
    return { pending_actions: actions.rows, open_items: tasks.rows };
  });
}
