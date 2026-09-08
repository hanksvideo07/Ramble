import * as Sentry from '@sentry/node';
import { config } from './config.ts';
import { log } from './logger.ts';

/**
 * Error reporting.
 *
 * Dormant unless SENTRY_DSN is set, and the whole module is written so that
 * absence is the normal case rather than a degraded one: every function here
 * is a no-op without a DSN, and nothing anywhere else has to check.
 *
 * What is deliberately never sent: transcript text, titles, summaries, entity
 * names, email addresses. A crash report is for finding a bug, and the
 * contents of someone's recordings are not evidence about a bug. User ids are
 * sent, because being able to say "this affected one account, not all of them"
 * is the difference between an incident and a curiosity.
 */

let enabled = false;

export function initErrorReporting(): void {
  const dsn = config.sentry.dsn;
  if (!dsn) {
    log.info('errors.reporting_disabled', { reason: 'SENTRY_DSN not set' });
    return;
  }

  Sentry.init({
    dsn,
    environment: config.sentry.environment,
    release: config.sentry.release,
    // Errors only. Ramble's latency is already measured in its own logs, and
    // performance tracing would carry request bodies with it.
    tracesSampleRate: 0,
    sendDefaultPii: false,
    beforeSend(event) {
      // Belt and braces: even if a message somewhere grows a transcript, it
      // does not leave the building.
      if (event.request) {
        delete event.request.data;
        delete event.request.cookies;
        delete event.request.headers;
      }
      return event;
    },
  });

  enabled = true;
  log.info('errors.reporting_enabled', { environment: config.sentry.environment });
}

export function isErrorReportingEnabled(): boolean {
  return enabled;
}

export interface ErrorContext {
  userId?: string | null;
  /** Where this happened, e.g. 'pipeline.understand' or 'route.POST /v1/rambles'. */
  where: string;
  /** Counts, ids, and states only — never content. */
  extra?: Record<string, unknown>;
}

export function captureError(error: unknown, context: ErrorContext): void {
  if (!enabled) return;
  Sentry.withScope((scope) => {
    scope.setTag('where', context.where);
    if (context.userId) scope.setUser({ id: context.userId });
    if (context.extra) scope.setContext('detail', context.extra);
    Sentry.captureException(error instanceof Error ? error : new Error(String(error)));
  });
}

/**
 * A crash that happened on someone's phone.
 *
 * Reported here rather than by an SDK inside the app: the device sends Apple's
 * own MetricKit diagnostic, and the server forwards it. That keeps a
 * third-party SDK out of an app built around private thoughts, while still
 * putting the crash somewhere a person will actually see it.
 */
export interface DeviceCrash {
  kind: 'crash' | 'hang' | 'disk-write' | 'cpu-exception';
  /** Apple's termination reason or exception type. */
  signature: string;
  /** The symbolicated frames, when the diagnostic carried them. */
  frames?: string[];
  appVersion?: string;
  osVersion?: string;
  deviceModel?: string;
  occurredAt?: string;
}

export function captureDeviceCrash(crash: DeviceCrash, userId: string | null): void {
  log.error('device.crash_reported', {
    kind: crash.kind,
    signature: crash.signature,
    app_version: crash.appVersion,
    os_version: crash.osVersion,
  });

  if (!enabled) return;
  Sentry.withScope((scope) => {
    scope.setTag('where', 'ios');
    scope.setTag('crash_kind', crash.kind);
    scope.setLevel(crash.kind === 'crash' ? 'fatal' : 'error');
    if (userId) scope.setUser({ id: userId });
    scope.setContext('device', {
      app_version: crash.appVersion,
      os_version: crash.osVersion,
      model: crash.deviceModel,
      occurred_at: crash.occurredAt,
    });
    if (crash.frames?.length) {
      scope.setContext('stack', { frames: crash.frames.slice(0, 60) });
    }
    Sentry.captureMessage(`iOS ${crash.kind}: ${crash.signature}`, 'fatal');
  });
}

/**
 * Notices when the pipeline stops working for everyone rather than failing one
 * recording.
 *
 * A single failed ramble is ordinary — a model timed out, an upload was
 * truncated. The thing worth waking someone for is a run of them, which is
 * exactly what nobody would notice from logs alone.
 */
class FailureStreak {
  private consecutive = 0;
  private lastAlertAt = 0;

  succeeded(): void {
    this.consecutive = 0;
  }

  failed(error: unknown): void {
    this.consecutive += 1;
    if (this.consecutive < config.sentry.alertAfterFailures) return;

    // One alert per hour at most. A pipeline that is properly broken will fail
    // hundreds of times, and burying the first report under the rest helps
    // nobody.
    const now = Date.now();
    if (now - this.lastAlertAt < 60 * 60_000) return;
    this.lastAlertAt = now;

    log.error('pipeline.failing_repeatedly', { consecutive: this.consecutive });
    captureError(error, {
      where: 'pipeline.streak',
      extra: { consecutive_failures: this.consecutive },
    });
  }

  get length(): number {
    return this.consecutive;
  }
}

export const pipelineFailures = new FailureStreak();
