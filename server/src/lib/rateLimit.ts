import { log } from './logger.ts';

/**
 * Throttling for the endpoints an attacker can hammer.
 *
 * Deliberately hand-rolled and narrow rather than a general middleware: the
 * only routes that need this are the credential ones, and what they need is
 * specific. Two rules matter more than the numbers.
 *
 * First, only FAILED attempts count. A limiter that counts every request
 * punishes the person who mistyped their password once and then logged in
 * correctly, and does nothing an attacker cares about.
 *
 * Second, the limit is applied per-address as well as per-IP. An IP limit
 * alone is defeated by a botnet; an address limit alone lets one IP walk the
 * whole user table. Both, and the stricter one wins.
 */

interface Window {
  hits: number;
  /** When the current window opened. */
  since: number;
}

export interface LimitRule {
  /** How many failures before the door closes. */
  max: number;
  /** Window length in milliseconds. */
  windowMs: number;
}

export class RateLimiter {
  private readonly windows = new Map<string, Window>();
  /**
   * Zero rather than `Date.now()`, so the class reads time only from what it
   * is given. Seeding it from the real clock left a limiter driven by an
   * injected clock unable to sweep at all, since the two never agreed.
   */
  private lastSweep = 0;

  constructor(private readonly rule: LimitRule) {}

  /**
   * How long the caller must wait, in seconds, or zero if they may proceed.
   * Checking does not itself count as an attempt — only `record` does.
   */
  retryAfter(key: string, now = Date.now()): number {
    this.sweep(now);
    const window = this.windows.get(key);
    if (!window) return 0;
    if (now - window.since >= this.rule.windowMs) {
      this.windows.delete(key);
      return 0;
    }
    if (window.hits < this.rule.max) return 0;
    return Math.ceil((this.rule.windowMs - (now - window.since)) / 1000);
  }

  /** Counts one failure against the key. */
  record(key: string, now = Date.now()): void {
    const window = this.windows.get(key);
    if (!window || now - window.since >= this.rule.windowMs) {
      this.windows.set(key, { hits: 1, since: now });
      return;
    }
    window.hits += 1;
  }

  /** Forgets a key's failures. Called when the credential finally works. */
  clear(key: string): void {
    this.windows.delete(key);
  }

  /**
   * Drops expired windows so a long-running process cannot accumulate an entry
   * per address ever tried. Amortized: swept at most once a minute, on access.
   */
  private sweep(now: number): void {
    if (now - this.lastSweep < 60_000) return;
    this.lastSweep = now;
    for (const [key, window] of this.windows) {
      if (now - window.since >= this.rule.windowMs) this.windows.delete(key);
    }
  }

  /** Test seam. */
  get size(): number {
    return this.windows.size;
  }
}

/**
 * Signing in. Ten failures from one address in fifteen minutes is already far
 * beyond a person who forgot which password they used.
 */
export const loginByIp = new RateLimiter({ max: 10, windowMs: 15 * 60_000 });

/**
 * Stricter per account, because this is the limit that matters when the
 * attempts are spread across many machines.
 */
export const loginByAccount = new RateLimiter({ max: 5, windowMs: 15 * 60_000 });

/** Account creation. Enough for a household, not enough to farm accounts. */
export const registerByIp = new RateLimiter({ max: 5, windowMs: 60 * 60_000 });

/** Thrown when a limiter refuses. Carries the wait so the client can say it. */
export class RateLimitedError extends Error {
  readonly statusCode = 429;

  constructor(readonly retryAfterSeconds: number) {
    super(
      retryAfterSeconds >= 60
        ? `Too many attempts. Try again in ${Math.ceil(retryAfterSeconds / 60)} minutes.`
        : 'Too many attempts. Try again in a moment.',
    );
    this.name = 'RateLimitedError';
  }
}

/**
 * Refuses if any of the given limiters is out of patience.
 *
 * The longest wait wins, so a caller is never told to retry sooner than a
 * limiter that is still holding the door shut.
 */
export function enforce(checks: { limiter: RateLimiter; key: string }[], context: string): void {
  let wait = 0;
  for (const check of checks) {
    wait = Math.max(wait, check.limiter.retryAfter(check.key));
  }
  if (wait > 0) {
    log.warn('ratelimit.refused', { context, retry_after_seconds: wait });
    throw new RateLimitedError(wait);
  }
}
