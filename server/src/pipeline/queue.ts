import { pool } from '../db/pool.ts';
import { log } from '../lib/logger.ts';
import { processRamble, type ProcessOptions } from './process.ts';

/**
 * In-process durable queue.
 *
 * Durability comes from the database, not from memory: rambles.processing_state
 * is the real work list. The in-memory queue is only a fast path for work
 * arriving while the process is alive. `recoverStuck` re-enqueues anything the
 * database still shows as unfinished, so a crash or restart resumes cleanly.
 *
 * A modular monolith wants exactly this much machinery. Swapping in Redis or
 * pg-boss later means replacing this file, nothing else.
 */

interface Job {
  rambleId: string;
  options: ProcessOptions;
  attempt: number;
}

const MAX_ATTEMPTS = 3;
const CONCURRENCY = 2;
/** Backoff before retrying a failed ramble: 5s, then 25s. */
const RETRY_DELAY_MS = (attempt: number) => 5_000 * 5 ** (attempt - 1);

const pending: Job[] = [];
const inFlight = new Set<string>();
let running = 0;

export function enqueue(rambleId: string, options: ProcessOptions = {}): void {
  if (inFlight.has(rambleId) || pending.some((j) => j.rambleId === rambleId)) return;
  pending.push({ rambleId, options, attempt: 1 });
  drain();
}

function drain(): void {
  while (running < CONCURRENCY && pending.length > 0) {
    const job = pending.shift();
    if (!job) break;
    void run(job);
  }
}

async function run(job: Job): Promise<void> {
  running += 1;
  inFlight.add(job.rambleId);
  try {
    await processRamble(job.rambleId, job.options);
  } catch (error) {
    if (job.attempt < MAX_ATTEMPTS) {
      const delay = RETRY_DELAY_MS(job.attempt);
      log.warn('queue.retrying', {
        ramble_id: job.rambleId,
        attempt: job.attempt,
        delay_ms: delay,
      });
      setTimeout(() => {
        pending.push({ ...job, attempt: job.attempt + 1 });
        drain();
      }, delay).unref();
    } else {
      log.error('queue.exhausted', {
        ramble_id: job.rambleId,
        attempts: job.attempt,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  } finally {
    running -= 1;
    inFlight.delete(job.rambleId);
    drain();
  }
}

/**
 * Re-enqueues rambles the database shows as unfinished. Run at startup, and
 * periodically to catch anything stalled mid-stage.
 */
export async function recoverStuck(olderThanMinutes = 5): Promise<number> {
  const { rows } = await pool.query<{ id: string }>(
    `SELECT id FROM rambles
      WHERE processing_state IN ('uploaded','transcribing','transcribed','understanding','embedding','failed')
        AND updated_at < now() - ($1 || ' minutes')::interval
      ORDER BY recorded_at
      LIMIT 50`,
    [olderThanMinutes],
  );
  for (const row of rows) enqueue(row.id);
  if (rows.length > 0) log.info('queue.recovered', { count: rows.length });
  return rows.length;
}

export function queueDepth(): { pending: number; running: number } {
  return { pending: pending.length, running };
}
