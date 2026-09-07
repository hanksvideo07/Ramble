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

  /** Everything still open: the "needs you" set across all rambles. */
  app.get('/v1/inbox', async (request) => {
    const user = await requireUser(request);
    const [actions, tasks] = await Promise.all([
      pool.query(
        `SELECT a.id, a.type, a.parameters, a.confidence, a.intent_class, a.risk,
                a.state, a.ramble_id, r.title AS ramble_title, a.created_at
           FROM actions a JOIN rambles r ON r.id = a.ramble_id
          WHERE a.user_id = $1 AND a.state = 'awaiting_confirmation'
          ORDER BY a.created_at DESC LIMIT 50`,
        [user.id],
      ),
      pool.query(
        `SELECT id, kind, title, body, attributes, ramble_id, created_at
           FROM extracted_items
          WHERE user_id = $1 AND status = 'open'
            AND kind IN ('task','reminder','commitment','follow_up')
          ORDER BY (attributes->>'due_at') NULLS LAST, created_at DESC
          LIMIT 50`,
        [user.id],
      ),
    ]);
    return { pending_actions: actions.rows, open_items: tasks.rows };
  });
}
