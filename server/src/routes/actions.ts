import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool } from '../db/pool.ts';
import { HttpError, requireUser } from '../lib/auth.ts';
import { track } from '../lib/analytics.ts';
import { approveAndExecute } from '../actions/executor.ts';
import { ACTION_DEFINITIONS, definitionFor } from '../actions/registry.ts';
import { emitWebhook } from '../integrations/webhooks.ts';

export async function actionRoutes(app: FastifyInstance): Promise<void> {
  app.get('/v1/actions', async (request) => {
    const user = await requireUser(request);
    const query = z
      .object({ state: z.string().optional(), limit: z.coerce.number().min(1).max(100).default(50) })
      .parse(request.query);

    const params: unknown[] = [user.id];
    let filter = '';
    if (query.state) {
      params.push(query.state.split(','));
      filter = `AND a.state = ANY($${params.length}::text[])`;
    }
    params.push(query.limit);

    const { rows } = await pool.query(
      `SELECT a.id, a.type, a.parameters, a.state, a.confidence, a.intent_class, a.risk,
              a.requires_confirmation, a.result, a.error, a.executed_at, a.created_at,
              a.ramble_id, r.title AS ramble_title
         FROM actions a JOIN rambles r ON r.id = a.ramble_id
        WHERE a.user_id = $1 ${filter}
        ORDER BY a.created_at DESC LIMIT $${params.length}`,
      params,
    );
    return {
      actions: rows.map((row) => ({
        ...row,
        label: definitionFor(row.type)?.label ?? row.type,
        target: definitionFor(row.type)?.target ?? 'server',
      })),
    };
  });

  app.post('/v1/actions/:id/confirm', async (request) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    await approveAndExecute(id, user.id);
    await track(user.id, 'action_confirmed', {});

    const { rows } = await pool.query(
      `SELECT id, type, state, result, error FROM actions WHERE id = $1 AND user_id = $2`,
      [id, user.id],
    );
    const action = rows[0];
    if (!action) throw new HttpError(404, 'Action not found.');
    return action;
  });

  app.post('/v1/actions/:id/cancel', async (request) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const { rows } = await pool.query(
      `UPDATE actions SET state = 'cancelled'
        WHERE id = $1 AND user_id = $2 AND state IN ('detected','awaiting_confirmation','failed')
        RETURNING id, state`,
      [id, user.id],
    );
    const action = rows[0];
    if (!action) throw new HttpError(404, 'Action not found or already run.');
    await track(user.id, 'action_cancelled', {});
    return action;
  });

  /**
   * Actions the device must run itself (Apple Calendar and Reminders live
   * behind EventKit). The app polls this, executes locally, then reports back.
   */
  app.get('/v1/actions/pending-device', async (request) => {
    const user = await requireUser(request);
    const clientTypes = Object.values(ACTION_DEFINITIONS)
      .filter((d) => d.target === 'client')
      .map((d) => d.type);

    const { rows } = await pool.query(
      `SELECT id, type, parameters, ramble_id
         FROM actions
        WHERE user_id = $1 AND state = 'approved' AND type = ANY($2::text[])
        ORDER BY created_at LIMIT 20`,
      [user.id, clientTypes],
    );
    return { actions: rows };
  });

  /** The device reports what happened after running a client-side action. */
  app.post('/v1/actions/:id/result', async (request) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const body = z
      .object({
        success: z.boolean(),
        result: z.record(z.unknown()).optional(),
        error: z.string().max(500).optional(),
      })
      .parse(request.body);

    const { rows } = await pool.query(
      `UPDATE actions
          SET state = $3, result = $4::jsonb, error = $5, executed_at = now()
        WHERE id = $1 AND user_id = $2 AND state IN ('approved','executing')
        RETURNING id, type, state`,
      [
        id,
        user.id,
        body.success ? 'completed' : 'failed',
        JSON.stringify(body.result ?? {}),
        body.error ?? null,
      ],
    );
    const action = rows[0];
    if (!action) throw new HttpError(404, 'Action not found or not awaiting a device result.');

    await track(user.id, body.success ? 'action_completed' : 'action_failed', { type: action.type });
    if (body.success) {
      await emitWebhook(user.id, 'action.completed', { action_id: id, type: action.type });
    }
    return action;
  });
}
