import { randomBytes } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool } from '../db/pool.ts';
import { config } from '../lib/config.ts';
import { HttpError, requireUser } from '../lib/auth.ts';
import { track } from '../lib/analytics.ts';
import { WEBHOOK_EVENTS } from '../integrations/webhooks.ts';

/**
 * Integration catalog shown in Settings. Users see product names; the words
 * MCP, OAuth, and adapter never appear outside the advanced section.
 */
const CATALOG = [
  {
    provider: 'apple_calendar',
    name: 'Apple Calendar',
    category: 'Calendar',
    // Runs entirely on-device through EventKit, so there is nothing to connect
    // server-side and the user's calendar never reaches our servers.
    connect: 'device',
    available: true,
  },
  {
    provider: 'apple_reminders',
    name: 'Apple Reminders',
    category: 'Tasks',
    connect: 'device',
    available: true,
  },
  { provider: 'google_calendar', name: 'Google Calendar', category: 'Calendar', connect: 'oauth', available: false },
  { provider: 'gmail', name: 'Gmail', category: 'Communication', connect: 'oauth', available: false },
  { provider: 'notion', name: 'Notion', category: 'Notes', connect: 'oauth', available: false },
  { provider: 'obsidian', name: 'Obsidian', category: 'Notes', connect: 'device', available: false },
  { provider: 'github', name: 'GitHub', category: 'Development', connect: 'oauth', available: false },
  { provider: 'todoist', name: 'Todoist', category: 'Tasks', connect: 'oauth', available: false },
] as const;

export async function integrationRoutes(app: FastifyInstance): Promise<void> {
  app.get('/v1/integrations', async (request) => {
    const user = await requireUser(request);
    const { rows } = await pool.query<{ provider: string; status: string; display_name: string | null }>(
      `SELECT provider, status, display_name FROM integrations WHERE user_id = $1`,
      [user.id],
    );
    const connected = new Map(rows.map((r) => [r.provider, r]));

    return {
      integrations: CATALOG.map((entry) => ({
        ...entry,
        // OAuth providers are only offered when the server actually holds
        // credentials for them; otherwise "Connect" would lead nowhere.
        available:
          entry.connect === 'oauth'
            ? Boolean(config.google.clientId && config.google.clientSecret)
            : entry.available,
        status: connected.get(entry.provider)?.status ?? 'disconnected',
      })),
    };
  });

  /** Records a device-side integration the user enabled in the app. */
  app.post('/v1/integrations/:provider/connect', async (request) => {
    const user = await requireUser(request);
    const { provider } = z.object({ provider: z.string().max(60) }).parse(request.params);
    const entry = CATALOG.find((c) => c.provider === provider);
    if (!entry) throw new HttpError(404, 'Unknown integration.');
    if (entry.connect !== 'device') {
      throw new HttpError(400, `${entry.name} must be connected through its sign-in flow.`);
    }

    await pool.query(
      `INSERT INTO integrations (user_id, provider, display_name, status)
       VALUES ($1,$2,$3,'connected')
       ON CONFLICT (user_id, provider) DO UPDATE SET status = 'connected', last_error = NULL`,
      [user.id, provider, entry.name],
    );
    await track(user.id, 'integration_connected', { provider });
    return { provider, status: 'connected' };
  });

  app.delete('/v1/integrations/:provider', async (request, reply) => {
    const user = await requireUser(request);
    const { provider } = z.object({ provider: z.string().max(60) }).parse(request.params);
    await pool.query(`DELETE FROM integrations WHERE user_id = $1 AND provider = $2`, [user.id, provider]);
    return reply.code(204).send();
  });

  // --- developer webhooks --------------------------------------------------

  app.get('/v1/webhooks', async (request) => {
    const user = await requireUser(request);
    const { rows } = await pool.query(
      `SELECT id, url, events, active, created_at FROM webhooks WHERE user_id = $1 ORDER BY created_at`,
      [user.id],
    );
    return { webhooks: rows, available_events: WEBHOOK_EVENTS };
  });

  app.post('/v1/webhooks', async (request, reply) => {
    const user = await requireUser(request);
    const body = z
      .object({
        url: z.string().url(),
        events: z.array(z.enum(WEBHOOK_EVENTS)).min(1),
      })
      .parse(request.body);

    const secret = randomBytes(24).toString('hex');
    const { rows } = await pool.query(
      `INSERT INTO webhooks (user_id, url, events, secret) VALUES ($1,$2,$3,$4)
       RETURNING id, url, events, active, created_at`,
      [user.id, body.url, body.events, secret],
    );
    // The secret is returned exactly once, at creation.
    return reply.code(201).send({ ...rows[0], secret });
  });

  app.delete('/v1/webhooks/:id', async (request, reply) => {
    const user = await requireUser(request);
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    await pool.query(`DELETE FROM webhooks WHERE id = $1 AND user_id = $2`, [id, user.id]);
    return reply.code(204).send();
  });
}
