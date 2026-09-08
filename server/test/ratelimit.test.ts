import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { RateLimiter, RateLimitedError, enforce } from '../src/lib/rateLimit.ts';

describe('rate limiting credentials', () => {
  it('lets a person through until they have genuinely been guessing', () => {
    const limiter = new RateLimiter({ max: 3, windowMs: 60_000 });
    for (let i = 0; i < 3; i += 1) {
      assert.equal(limiter.retryAfter('1.2.3.4'), 0);
      limiter.record('1.2.3.4');
    }
    assert.ok(limiter.retryAfter('1.2.3.4') > 0);
  });

  it('forgives everything the moment the password works', () => {
    // Someone cycling through their own old passwords must not lock
    // themselves out of the account they just proved they own.
    const limiter = new RateLimiter({ max: 3, windowMs: 60_000 });
    limiter.record('me@example.com');
    limiter.record('me@example.com');
    limiter.clear('me@example.com');
    assert.equal(limiter.retryAfter('me@example.com'), 0);
  });

  it('opens the door again once the window has passed', () => {
    const limiter = new RateLimiter({ max: 1, windowMs: 1_000 });
    const start = 1_000_000;
    limiter.record('k', start);
    assert.ok(limiter.retryAfter('k', start) > 0);
    assert.equal(limiter.retryAfter('k', start + 1_001), 0);
  });

  it('keeps one address\'s failures away from another\'s', () => {
    const limiter = new RateLimiter({ max: 1, windowMs: 60_000 });
    limiter.record('a@example.com');
    assert.ok(limiter.retryAfter('a@example.com') > 0);
    assert.equal(limiter.retryAfter('b@example.com'), 0);
  });

  it('reports the longest wait when several limits apply', () => {
    // Being told to retry in ten seconds by the lenient limiter, while the
    // strict one holds the door for another ten minutes, is a lie.
    const lenient = new RateLimiter({ max: 1, windowMs: 10_000 });
    const strict = new RateLimiter({ max: 1, windowMs: 600_000 });
    lenient.record('k');
    strict.record('k');
    try {
      enforce([{ limiter: lenient, key: 'k' }, { limiter: strict, key: 'k' }], 'login');
      assert.fail('should have refused');
    } catch (error) {
      assert.ok(error instanceof RateLimitedError);
      assert.ok(error.retryAfterSeconds > 500);
    }
  });

  it('does not grow a window per address forever', () => {
    const limiter = new RateLimiter({ max: 5, windowMs: 1_000 });
    const start = 2_000_000;
    for (let i = 0; i < 50; i += 1) limiter.record(`ip-${i}`, start);
    assert.equal(limiter.size, 50);
    // A sweep runs at most once a minute, so step past both it and the window.
    limiter.retryAfter('probe', start + 61_000);
    assert.equal(limiter.size, 0);
  });

  it('checking is free; only a failure counts', () => {
    const limiter = new RateLimiter({ max: 1, windowMs: 60_000 });
    for (let i = 0; i < 10; i += 1) limiter.retryAfter('k');
    assert.equal(limiter.retryAfter('k'), 0);
  });
});
