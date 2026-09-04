import { createHmac, timingSafeEqual } from 'node:crypto';
import { pool } from '../db/pool.ts';
import { log } from '../lib/logger.ts';

export const WEBHOOK_EVENTS = [
  'ramble.created',
  'ramble.transcribed',
  'ramble.processed',
  'task.created',
  'idea.created',
  'action.requested',
  'action.confirmed',
  'action.completed',
] as const;

export type WebhookEvent = (typeof WEBHOOK_EVENTS)[number];

const MAX_ATTEMPTS = 5;

/** Exponential backoff: 30s, 2m, 8m, 32m. */
function nextAttemptDelayMs(attempts: number): number {
  return 30_000 * 4 ** (attempts - 1);
}

/**
 * Queues a webhook for every endpoint of this user subscribed to `event`.
 * Delivery happens in the background so a slow endpoint never blocks the
 * processing pipeline.
 */
export async function emitWebhook(
  userId: string,
  event: string,
  payload: Record<string, unknown>,
): Promise<void> {
  const { rows } = await pool.query<{ id: string }>(
    `SELECT id FROM webhooks
      WHERE user_id = $1 AND active = true AND $2 = ANY(events)`,
    [userId, event],
  );
  if (rows.length === 0) return;

  const body = JSON.stringify({ event, data: payload, emitted_at: new Date().toISOString() });
  for (const webhook of rows) {
    await pool.query(
      `INSERT INTO webhook_deliveries (webhook_id, event, payload, next_attempt_at)
       VALUES ($1, $2, $3::jsonb, now())`,
      [webhook.id, event, body],
    );
  }
}

export function signPayload(secret: string, body: string, timestamp: number): string {
  return createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex');
}

/** Constant-time comparison so a receiver can verify without a timing leak. */
export function verifySignature(
  secret: string,
  body: string,
  timestamp: number,
  signature: string,
): boolean {
  const expected = signPayload(secret, body, timestamp);
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(signature, 'utf8');
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Delivers one batch of due webhooks. Called on a timer by the worker. */
export async function deliverPendingWebhooks(limit = 20): Promise<number> {
  const { rows } = await pool.query<{
    id: string;
    webhook_id: string;
    event: string;
    payload: unknown;
    attempts: number;
    url: string;
    secret: string;
  }>(
    `SELECT d.id, d.webhook_id, d.event, d.payload, d.attempts, w.url, w.secret
       FROM webhook_deliveries d
       JOIN webhooks w ON w.id = d.webhook_id
      WHERE d.status = 'pending'
        AND d.next_attempt_at <= now()
        AND w.active = true
      ORDER BY d.next_attempt_at
      LIMIT $1
      FOR UPDATE OF d SKIP LOCKED`,
    [limit],
  );

  for (const delivery of rows) {
    const body = typeof delivery.payload === 'string' ? delivery.payload : JSON.stringify(delivery.payload);
    const timestamp = Math.floor(Date.now() / 1000);
    const attempts = delivery.attempts + 1;

    try {
      const response = await fetch(delivery.url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Ramble-Event': delivery.event,
          'X-Ramble-Timestamp': String(timestamp),
          'X-Ramble-Signature': signPayload(delivery.secret, body, timestamp),
        },
        body,
        signal: AbortSignal.timeout(10_000),
      });

      if (response.ok) {
        await pool.query(
          `UPDATE webhook_deliveries
              SET status = 'delivered', attempts = $2, response_code = $3
            WHERE id = $1`,
          [delivery.id, attempts, response.status],
        );
        continue;
      }
      await rescheduleOrFail(delivery.id, attempts, response.status);
    } catch (error) {
      log.warn('webhook.delivery_error', {
        delivery_id: delivery.id,
        error: error instanceof Error ? error.message : String(error),
      });
      await rescheduleOrFail(delivery.id, attempts, null);
    }
  }
  return rows.length;
}

async function rescheduleOrFail(
  deliveryId: string,
  attempts: number,
  responseCode: number | null,
): Promise<void> {
  if (attempts >= MAX_ATTEMPTS) {
    await pool.query(
      `UPDATE webhook_deliveries SET status = 'failed', attempts = $2, response_code = $3 WHERE id = $1`,
      [deliveryId, attempts, responseCode],
    );
    return;
  }
  await pool.query(
    `UPDATE webhook_deliveries
        SET attempts = $2, response_code = $3,
            next_attempt_at = now() + ($4 || ' milliseconds')::interval
      WHERE id = $1`,
    [deliveryId, attempts, responseCode, nextAttemptDelayMs(attempts)],
  );
}
