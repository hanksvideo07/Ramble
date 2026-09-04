import pg from 'pg';
import { config } from '../lib/config.ts';

/**
 * pgvector sends vectors as a text type; parse them back into number[] so
 * callers never deal with the wire format.
 */
const VECTOR_OID_QUERY = `SELECT oid FROM pg_type WHERE typname = 'vector'`;

export const pool = new pg.Pool({
  connectionString: config.databaseUrl,
  max: 10,
  idleTimeoutMillis: 30_000,
});

let vectorParserRegistered = false;

export async function registerVectorParser(): Promise<void> {
  if (vectorParserRegistered) return;
  const { rows } = await pool.query<{ oid: number }>(VECTOR_OID_QUERY);
  const oid = rows[0]?.oid;
  if (oid) {
    pg.types.setTypeParser(oid, (value: string) => JSON.parse(value) as number[]);
  }
  vectorParserRegistered = true;
}

export type Queryable = Pick<pg.PoolClient, 'query'>;

/** Runs `fn` inside a transaction, rolling back on any throw. */
export async function withTransaction<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

/** Formats a JS number[] into the literal pgvector expects. */
export function toVectorLiteral(values: number[]): string {
  return `[${values.join(',')}]`;
}
