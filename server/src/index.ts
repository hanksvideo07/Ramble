import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import Fastify from 'fastify';
import { ZodError } from 'zod';
import { migrate } from './db/migrate.ts';
import { pool, registerVectorParser } from './db/pool.ts';
import { capabilityReport, config } from './lib/config.ts';
import { HttpError } from './lib/auth.ts';
import { RateLimitedError } from './lib/rateLimit.ts';
import { log } from './lib/logger.ts';
import { ensureBucket } from './lib/storage.ts';
import { deliverPendingWebhooks } from './integrations/webhooks.ts';
import { queueDepth, recoverStuck } from './pipeline/queue.ts';
import { actionRoutes } from './routes/actions.ts';
import { authRoutes } from './routes/auth.ts';
import { embeddingRoutes } from './routes/embeddings.ts';
import { entityRoutes } from './routes/entities.ts';
import { integrationRoutes } from './routes/integrations.ts';
import { rambleRoutes } from './routes/rambles.ts';
import { searchRoutes } from './routes/search.ts';

export async function buildServer() {
  const app = Fastify({
    logger: false,
    bodyLimit: 25 * 1024 * 1024,
    // Railway terminates TLS in front of us, so without this every request
    // appears to come from the proxy and a per-IP limit would throttle the
    // whole world together.
    trustProxy: true,
  });

  await app.register(cors, { origin: true });
  await app.register(multipart, {
    // Roughly an hour of AAC at 64 kbps, with headroom for longer sessions.
    limits: { fileSize: 200 * 1024 * 1024, files: 1 },
  });

  app.setErrorHandler((error, request, reply) => {
    if (error instanceof RateLimitedError) {
      return reply
        .code(429)
        .header('Retry-After', String(error.retryAfterSeconds))
        .send({ error: error.message });
    }
    if (error instanceof HttpError) {
      return reply.code(error.statusCode).send({ error: error.message });
    }
    if (error instanceof ZodError) {
      return reply.code(400).send({
        error: 'Invalid request.',
        details: error.issues.map((i) => ({ path: i.path.join('.'), message: i.message })),
      });
    }
    if ((error as { statusCode?: number }).statusCode === 413) {
      return reply.code(413).send({ error: 'That recording is too large to upload.' });
    }
    log.error('request.unhandled', {
      method: request.method,
      url: request.url,
      error: error instanceof Error ? error.message : String(error),
    });
    // Never leak internals to the client.
    return reply.code(500).send({ error: 'Something went wrong on our end.' });
  });

  app.get('/v1/health', async () => ({
    status: 'ok',
    version: '0.1.0',
    // Tells the client which capabilities are real vs. mocked, so the app can
    // say so plainly instead of presenting stand-in output as genuine.
    capabilities: capabilityReport(),
    queue: queueDepth(),
  }));

  await app.register(authRoutes);
  await app.register(rambleRoutes);
  await app.register(searchRoutes);
  await app.register(entityRoutes);
  await app.register(actionRoutes);
  await app.register(integrationRoutes);
  await app.register(embeddingRoutes);

  return app;
}

async function main() {
  await migrate();
  await registerVectorParser();
  await ensureBucket();

  const app = await buildServer();
  await app.listen({ port: config.port, host: '0.0.0.0' });

  log.info('server.started', {
    port: config.port,
    capabilities: capabilityReport(),
  });

  // Resume anything interrupted by the last shutdown, then keep sweeping.
  await recoverStuck(0);
  const recovery = setInterval(() => void recoverStuck(5), 60_000);
  const webhooks = setInterval(() => void deliverPendingWebhooks(), 10_000);
  recovery.unref();
  webhooks.unref();

  const shutdown = async (signal: string) => {
    log.info('server.stopping', { signal });
    clearInterval(recovery);
    clearInterval(webhooks);
    await app.close();
    await pool.end();
    process.exit(0);
  };
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    log.error('server.failed_to_start', { error: error instanceof Error ? error.message : String(error) });
    console.error(error);
    process.exit(1);
  });
}
