import { config } from './config.ts';

type Level = 'debug' | 'info' | 'warn' | 'error';
const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };
const threshold = ORDER[(config.logLevel as Level) in ORDER ? (config.logLevel as Level) : 'info'];

/**
 * Structured logging. Transcript and extraction text is private, so callers
 * pass identifiers and counts rather than content; `redact` is available for
 * the rare case where a snippet genuinely aids debugging.
 */
function emit(level: Level, message: string, fields: Record<string, unknown> = {}) {
  if (ORDER[level] < threshold) return;
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    message,
    ...fields,
  });
  if (level === 'error' || level === 'warn') console.error(line);
  else console.log(line);
}

export const log = {
  debug: (m: string, f?: Record<string, unknown>) => emit('debug', m, f),
  info: (m: string, f?: Record<string, unknown>) => emit('info', m, f),
  warn: (m: string, f?: Record<string, unknown>) => emit('warn', m, f),
  error: (m: string, f?: Record<string, unknown>) => emit('error', m, f),
};

/** Length + hash stand in for private text in logs. */
export function redact(text: string | null | undefined): string {
  if (!text) return '<empty>';
  return `<${text.length} chars>`;
}

/** Times an operation and logs its latency for the observability targets. */
export async function timed<T>(
  metric: string,
  fields: Record<string, unknown>,
  fn: () => Promise<T>,
): Promise<T> {
  const started = Date.now();
  try {
    const result = await fn();
    log.info(metric, { ...fields, duration_ms: Date.now() - started, ok: true });
    return result;
  } catch (error) {
    log.error(metric, {
      ...fields,
      duration_ms: Date.now() - started,
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    });
    throw error;
  }
}
