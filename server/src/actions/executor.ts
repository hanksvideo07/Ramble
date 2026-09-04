import { pool } from '../db/pool.ts';
import { log } from '../lib/logger.ts';
import { emitWebhook } from '../integrations/webhooks.ts';
import { definitionFor, validateParameters } from './registry.ts';

export interface ActionRow {
  id: string;
  user_id: string;
  ramble_id: string;
  type: string;
  parameters: Record<string, unknown>;
  state: string;
  requires_confirmation: boolean;
}

/**
 * Executes a server-side action. Client-target actions (calendar, reminders)
 * are never executed here: they are handed to the device, which reports back
 * through POST /v1/actions/:id/result.
 */
export async function executeAction(action: ActionRow): Promise<void> {
  const definition = definitionFor(action.type);
  if (!definition) {
    await failAction(action.id, `Unknown action type "${action.type}".`);
    return;
  }
  if (definition.target === 'client') {
    // Leave it approved and waiting; the device will claim it.
    log.info('action.awaiting_device', { action_id: action.id, type: action.type });
    return;
  }

  const validated = validateParameters(action.type, action.parameters);
  if (!validated.ok) {
    await failAction(action.id, validated.error);
    return;
  }

  const claimed = await claimForExecution(action.id);
  if (!claimed) {
    // Another worker already moved it out of 'approved'. Idempotency guard.
    log.info('action.already_claimed', { action_id: action.id });
    return;
  }

  try {
    const result = await runServerAction(action, validated.value);
    await pool.query(
      `UPDATE actions
          SET state = 'completed', result = $2, executed_at = now(), error = NULL
        WHERE id = $1`,
      [action.id, JSON.stringify(result)],
    );
    log.info('action.completed', { action_id: action.id, type: action.type });
    await emitWebhook(action.user_id, 'action.completed', {
      action_id: action.id,
      type: action.type,
      ramble_id: action.ramble_id,
    });
  } catch (error) {
    await failAction(action.id, error instanceof Error ? error.message : String(error));
  }
}

/**
 * Moves an approved action to 'executing' only if it is still approved. The
 * conditional UPDATE is the idempotency guard: a retried or duplicated job
 * cannot execute the same action twice.
 */
async function claimForExecution(actionId: string): Promise<boolean> {
  const { rowCount } = await pool.query(
    `UPDATE actions SET state = 'executing'
      WHERE id = $1 AND state = 'approved'`,
    [actionId],
  );
  return (rowCount ?? 0) > 0;
}

async function failAction(actionId: string, error: string): Promise<void> {
  await pool.query(`UPDATE actions SET state = 'failed', error = $2 WHERE id = $1`, [
    actionId,
    error,
  ]);
  log.error('action.failed', { action_id: actionId, error });
}

async function runServerAction(
  action: ActionRow,
  parameters: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  switch (action.type) {
    case 'note.create': {
      const { rows } = await pool.query<{ id: string }>(
        `INSERT INTO extracted_items (ramble_id, user_id, kind, title, body, confidence, attributes)
         VALUES ($1, $2, 'note', $3, $4, 1.0, '{"created_by":"action"}'::jsonb)
         RETURNING id`,
        [action.ramble_id, action.user_id, parameters.title, parameters.body ?? null],
      );
      return { item_id: rows[0]?.id };
    }

    case 'task.create': {
      const attributes: Record<string, unknown> = { created_by: 'action' };
      if (parameters.due_at) attributes.due_at = parameters.due_at;
      if (parameters.priority) attributes.priority = parameters.priority;
      const { rows } = await pool.query<{ id: string }>(
        `INSERT INTO extracted_items (ramble_id, user_id, kind, title, confidence, attributes)
         VALUES ($1, $2, 'task', $3, 1.0, $4::jsonb)
         RETURNING id`,
        [action.ramble_id, action.user_id, parameters.title, JSON.stringify(attributes)],
      );
      return { item_id: rows[0]?.id };
    }

    case 'email.draft': {
      // A draft is deliberately inert: it is stored for the user to review and
      // send themselves. Nothing leaves the system.
      const { rows } = await pool.query<{ id: string }>(
        `INSERT INTO extracted_items (ramble_id, user_id, kind, title, body, confidence, attributes)
         VALUES ($1, $2, 'note', $3, $4, 1.0, $5::jsonb)
         RETURNING id`,
        [
          action.ramble_id,
          action.user_id,
          `Draft email${parameters.subject ? `: ${parameters.subject}` : ''}`,
          parameters.body ?? '',
          JSON.stringify({ created_by: 'action', kind_hint: 'email_draft', to: parameters.to ?? [] }),
        ],
      );
      return { draft_item_id: rows[0]?.id, sent: false };
    }

    case 'webhook.trigger': {
      await emitWebhook(action.user_id, String(parameters.event), {
        ...(parameters.payload as Record<string, unknown> | undefined),
        ramble_id: action.ramble_id,
      });
      return { emitted: true };
    }

    // Reaching a real external service requires connected credentials. Until an
    // adapter is wired, fail loudly rather than reporting a success that never
    // happened.
    case 'email.send':
    case 'integration.invoke':
    case 'mcp.invoke':
      throw new Error(
        `${action.type} needs a connected integration. Connect it in Settings, then retry this action.`,
      );

    default:
      throw new Error(`No server executor for action type "${action.type}".`);
  }
}

/**
 * Approves an action and executes it if it runs server-side.
 * Used both by the pipeline (auto-approved actions) and by user confirmation.
 */
export async function approveAndExecute(actionId: string, userId: string): Promise<void> {
  const { rows } = await pool.query<ActionRow>(
    `UPDATE actions
        SET state = 'approved', confirmed_at = now()
      WHERE id = $1 AND user_id = $2
        AND state IN ('detected','awaiting_confirmation','failed')
      RETURNING id, user_id, ramble_id, type, parameters, state, requires_confirmation`,
    [actionId, userId],
  );
  const action = rows[0];
  if (!action) return;
  await emitWebhook(userId, 'action.confirmed', { action_id: action.id, type: action.type });
  await executeAction(action);
}
