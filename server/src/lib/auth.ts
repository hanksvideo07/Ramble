import { createHash, randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import type { FastifyRequest } from 'fastify';
import { pool } from '../db/pool.ts';

const scrypt = promisify(scryptCallback) as (
  password: string,
  salt: string,
  keylen: number,
) => Promise<Buffer>;

const SESSION_TTL_DAYS = 90;

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16).toString('hex');
  const derived = await scrypt(password, salt, 64);
  return `scrypt$${salt}$${derived.toString('hex')}`;
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const [scheme, salt, hash] = stored.split('$');
  if (scheme !== 'scrypt' || !salt || !hash) return false;
  const derived = await scrypt(password, salt, 64);
  const expected = Buffer.from(hash, 'hex');
  return derived.length === expected.length && timingSafeEqual(derived, expected);
}

/**
 * Session tokens are random and stored only as a hash, so a database leak does
 * not hand out live sessions.
 */
export async function createSession(userId: string, device?: string): Promise<{ token: string; expiresAt: Date }> {
  const token = randomBytes(32).toString('base64url');
  const expiresAt = new Date(Date.now() + SESSION_TTL_DAYS * 24 * 60 * 60 * 1000);
  await pool.query(
    `INSERT INTO sessions (user_id, token_hash, device, expires_at) VALUES ($1,$2,$3,$4)`,
    [userId, hashToken(token), device ?? null, expiresAt],
  );
  return { token, expiresAt };
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

export async function revokeSession(token: string): Promise<void> {
  await pool.query(`DELETE FROM sessions WHERE token_hash = $1`, [hashToken(token)]);
}

export interface AuthedUser {
  id: string;
  email: string;
  profile: string;
  settings: Record<string, unknown>;
  onboardedAt: Date | null;
}

/**
 * Resolves the bearer token to a user. Every authenticated route uses this and
 * then scopes its queries by the returned id; no route derives a user id from
 * a request body or path parameter.
 */
export async function authenticate(request: FastifyRequest): Promise<AuthedUser | null> {
  const header = request.headers.authorization;
  if (!header?.startsWith('Bearer ')) return null;
  const token = header.slice('Bearer '.length).trim();
  if (!token) return null;

  const { rows } = await pool.query<{
    id: string;
    email: string;
    profile: string;
    settings: Record<string, unknown>;
    onboarded_at: Date | null;
  }>(
    `SELECT u.id, u.email, u.profile, u.settings, u.onboarded_at
       FROM sessions s JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = $1 AND s.expires_at > now()`,
    [hashToken(token)],
  );
  const row = rows[0];
  if (!row) return null;
  return {
    id: row.id,
    email: row.email,
    profile: row.profile,
    settings: row.settings ?? {},
    onboardedAt: row.onboarded_at,
  };
}

export class HttpError extends Error {
  constructor(readonly statusCode: number, message: string) {
    super(message);
  }
}

/** Throws 401 rather than returning null, so route handlers stay linear. */
export async function requireUser(request: FastifyRequest): Promise<AuthedUser> {
  const user = await authenticate(request);
  if (!user) throw new HttpError(401, 'Authentication required.');
  return user;
}
