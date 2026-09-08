import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool } from '../db/pool.ts';
import { createSession, hashPassword, requireUser, revokeSession, verifyPassword } from '../lib/auth.ts';
import { HttpError } from '../lib/auth.ts';
import { track } from '../lib/analytics.ts';
import {
  enforce,
  loginByAccount,
  loginByIp,
  registerByIp,
} from '../lib/rateLimit.ts';

const credentialsSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8, 'Password must be at least 8 characters.'),
  display_name: z.string().max(120).optional(),
  device: z.string().max(80).optional(),
});

export async function authRoutes(app: FastifyInstance): Promise<void> {
  app.post('/v1/auth/register', async (request, reply) => {
    enforce([{ limiter: registerByIp, key: request.ip }], 'register');
    const body = credentialsSchema.parse(request.body);
    const existing = await pool.query(`SELECT 1 FROM users WHERE email = $1`, [body.email.toLowerCase()]);
    if ((existing.rowCount ?? 0) > 0) {
      // Counts against the limit: walking a list of addresses to learn which
      // are taken is the other thing this endpoint can be used for.
      registerByIp.record(request.ip);
      throw new HttpError(409, 'An account with that email already exists.');
    }

    const { rows } = await pool.query<{ id: string }>(
      `INSERT INTO users (email, password_hash, display_name) VALUES ($1,$2,$3) RETURNING id`,
      [body.email.toLowerCase(), await hashPassword(body.password), body.display_name ?? null],
    );
    const userId = rows[0]!.id;
    registerByIp.record(request.ip);
    const session = await createSession(userId, body.device);
    await track(userId, 'account_created', {});

    return reply.code(201).send({
      token: session.token,
      expires_at: session.expiresAt.toISOString(),
      user: { id: userId, email: body.email.toLowerCase(), profile: 'other', onboarded: false },
    });
  });

  app.post('/v1/auth/login', async (request) => {
    const body = credentialsSchema.parse(request.body);
    const account = body.email.toLowerCase();
    enforce(
      [
        { limiter: loginByIp, key: request.ip },
        { limiter: loginByAccount, key: account },
      ],
      'login',
    );
    const { rows } = await pool.query<{
      id: string;
      email: string;
      password_hash: string;
      profile: string;
      onboarded_at: Date | null;
    }>(
      `SELECT id, email, password_hash, profile, onboarded_at FROM users WHERE email = $1`,
      [account],
    );
    const user = rows[0];
    // Same error for unknown email and wrong password, so the response does
    // not reveal which addresses have accounts.
    if (!user || !(await verifyPassword(body.password, user.password_hash))) {
      loginByIp.record(request.ip);
      loginByAccount.record(account);
      throw new HttpError(401, 'Incorrect email or password.');
    }

    // The credential worked, so the failures before it were a person
    // misremembering rather than someone guessing.
    loginByIp.clear(request.ip);
    loginByAccount.clear(account);

    const session = await createSession(user.id, body.device);
    return {
      token: session.token,
      expires_at: session.expiresAt.toISOString(),
      user: {
        id: user.id,
        email: user.email,
        profile: user.profile,
        onboarded: user.onboarded_at != null,
      },
    };
  });

  app.post('/v1/auth/logout', async (request, reply) => {
    const header = request.headers.authorization;
    if (header?.startsWith('Bearer ')) await revokeSession(header.slice(7).trim());
    return reply.code(204).send();
  });

  app.get('/v1/me', async (request) => {
    const user = await requireUser(request);
    return {
      id: user.id,
      email: user.email,
      profile: user.profile,
      settings: user.settings,
      onboarded: user.onboardedAt != null,
    };
  });

  app.patch('/v1/me', async (request) => {
    const user = await requireUser(request);
    const body = z
      .object({
        profile: z.enum(['student', 'founder', 'executive', 'creator', 'developer', 'other']).optional(),
        display_name: z.string().max(120).optional(),
        settings: z.record(z.unknown()).optional(),
        onboarded: z.boolean().optional(),
      })
      .parse(request.body);

    const { rows } = await pool.query<{ profile: string; settings: Record<string, unknown>; onboarded_at: Date | null }>(
      `UPDATE users
          SET profile = COALESCE($2, profile),
              display_name = COALESCE($3, display_name),
              settings = CASE WHEN $4::jsonb IS NULL THEN settings ELSE settings || $4::jsonb END,
              onboarded_at = CASE WHEN $5::boolean IS TRUE AND onboarded_at IS NULL THEN now() ELSE onboarded_at END
        WHERE id = $1
        RETURNING profile, settings, onboarded_at`,
      [
        user.id,
        body.profile ?? null,
        body.display_name ?? null,
        body.settings ? JSON.stringify(body.settings) : null,
        body.onboarded ?? null,
      ],
    );
    if (body.onboarded && !user.onboardedAt) await track(user.id, 'onboarding_completed', {});
    const updated = rows[0]!;
    return {
      id: user.id,
      email: user.email,
      profile: updated.profile,
      settings: updated.settings,
      onboarded: updated.onboarded_at != null,
    };
  });

  /** Full export of everything stored for this user. */
  app.get('/v1/me/export', async (request) => {
    const user = await requireUser(request);
    const tables = [
      'rambles', 'transcripts', 'transcript_segments', 'transcript_sections',
      'extracted_items', 'entities', 'entity_mentions', 'relationships',
      'actions', 'integrations', 'webhooks',
    ];
    const data: Record<string, unknown[]> = {};
    for (const table of tables) {
      const { rows } = await pool.query(`SELECT * FROM ${table} WHERE user_id = $1`, [user.id]);
      data[table] = rows;
    }
    return { exported_at: new Date().toISOString(), user: { id: user.id, email: user.email }, data };
  });

  /** Irreversible account deletion. Cascades remove every owned row. */
  app.delete('/v1/me', async (request, reply) => {
    const user = await requireUser(request);
    const body = z.object({ confirm: z.literal('DELETE') }).parse(request.body);
    if (body.confirm !== 'DELETE') throw new HttpError(400, 'Confirmation required.');
    await pool.query(`DELETE FROM users WHERE id = $1`, [user.id]);
    return reply.code(204).send();
  });
}
