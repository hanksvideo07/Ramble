import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireUser } from '../lib/auth.ts';
import { captureDeviceCrash } from '../lib/errors.ts';

/**
 * Crashes and hangs reported by the app.
 *
 * The app carries no crash-reporting SDK. It uses Apple's own MetricKit, which
 * is already on the device, already sanctioned, and already collecting this —
 * and posts the diagnostic here. The server is what forwards it onward.
 *
 * That ordering is deliberate. An app built around people's private thoughts
 * should not be linking a third-party SDK with permission to read its memory
 * and its network traffic. This way crashes still reach somewhere a person
 * will look, and the only thing that ever leaves the phone is a stack trace.
 */
const crashSchema = z.object({
  kind: z.enum(['crash', 'hang', 'disk-write', 'cpu-exception']),
  signature: z.string().min(1).max(500),
  frames: z.array(z.string().max(500)).max(120).optional(),
  app_version: z.string().max(40).optional(),
  os_version: z.string().max(40).optional(),
  device_model: z.string().max(60).optional(),
  occurred_at: z.string().max(40).optional(),
});

export async function diagnosticRoutes(app: FastifyInstance): Promise<void> {
  app.post('/v1/diagnostics/crashes', async (request, reply) => {
    const user = await requireUser(request);
    const body = z
      .object({ reports: z.array(crashSchema).min(1).max(20) })
      .parse(request.body);

    for (const report of body.reports) {
      captureDeviceCrash(
        {
          kind: report.kind,
          signature: report.signature,
          frames: report.frames,
          appVersion: report.app_version,
          osVersion: report.os_version,
          deviceModel: report.device_model,
          occurredAt: report.occurred_at,
        },
        user.id,
      );
    }

    return reply.code(202).send({ received: body.reports.length });
  });
}
