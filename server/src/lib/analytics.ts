import { pool } from '../db/pool.ts';
import { log } from './logger.ts';

/**
 * Product analytics. Properties carry counts, kinds, and latencies — never
 * transcript text, titles, or entity names.
 */
export async function track(
  userId: string | null,
  name: string,
  properties: Record<string, unknown> = {},
): Promise<void> {
  try {
    await pool.query(
      `INSERT INTO analytics_events (user_id, name, properties) VALUES ($1,$2,$3::jsonb)`,
      [userId, name, JSON.stringify(properties)],
    );
  } catch (error) {
    // Analytics must never break a request.
    log.warn('analytics.write_failed', { name, error: String(error) });
  }
}
