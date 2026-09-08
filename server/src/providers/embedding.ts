import { createHash } from 'node:crypto';
import { config } from '../lib/config.ts';
import { log } from '../lib/logger.ts';
import type { EmbeddingProvider } from './types.ts';

/**
 * Deterministic hash-based vectors. Not semantically meaningful, but stable
 * across runs, so hybrid search, storage, and ranking code can all be tested
 * without an embedding API key. Lexical search still works normally, so search
 * remains useful in mock mode.
 */
class MockEmbeddingProvider implements EmbeddingProvider {
  readonly name = 'mock';
  readonly model = 'mock-hash';
  readonly mocked = true;

  constructor(readonly dimension: number) {}

  async embed(texts: string[]): Promise<number[][]> {
    return texts.map((text) => this.hashVector(text));
  }

  private hashVector(text: string): number[] {
    // Sum one unit vector per token, so texts sharing tokens land near each
    // other under cosine similarity.
    const vector = new Array<number>(this.dimension).fill(0);
    const tokens = text.toLowerCase().match(/[a-z0-9']+/g) ?? [];
    for (const token of tokens) {
      const digest = createHash('sha256').update(token).digest();
      for (let i = 0; i < 8; i += 1) {
        const slot = digest.readUInt16BE(i * 2) % this.dimension;
        const sign = (digest[16 + i] ?? 0) % 2 === 0 ? 1 : -1;
        vector[slot] = (vector[slot] ?? 0) + sign;
      }
    }
    const norm = Math.sqrt(vector.reduce((sum, v) => sum + v * v, 0));
    return norm === 0 ? vector : vector.map((v) => v / norm);
  }
}

class OpenAIEmbeddingProvider implements EmbeddingProvider {
  readonly name = 'openai';
  readonly mocked = false;

  constructor(
    private readonly apiKey: string,
    readonly model: string,
    readonly dimension: number,
  ) {}

  async embed(texts: string[]): Promise<number[][]> {
    if (texts.length === 0) return [];
    const response = await fetch('https://api.openai.com/v1/embeddings', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ model: this.model, input: texts, dimensions: this.dimension }),
    });
    if (!response.ok) {
      throw new Error(`OpenAI embeddings returned ${response.status}: ${await response.text()}`);
    }
    const body = (await response.json()) as { data: { index: number; embedding: number[] }[] };
    // The API may return results out of order; restore the input order.
    const ordered = new Array<number[]>(texts.length);
    for (const row of body.data) ordered[row.index] = row.embedding;
    return ordered;
  }
}

/**
 * Embeddings through OpenRouter, so the fallback needs no key beyond the one
 * the server already has.
 *
 * OpenRouter passes OpenAI's `dimensions` parameter through, which matters
 * more than it looks: it lets the server emit vectors the same width as
 * Apple's on-device model, so switching between them needs no migration and
 * no re-sizing of the column. The two are still different vector spaces —
 * same width, different meaning — which is why every vector is stamped with
 * the space that produced it and search refuses to cross between them.
 */
class OpenRouterEmbeddingProvider implements EmbeddingProvider {
  readonly name = 'openrouter';
  readonly mocked = false;

  constructor(
    private readonly apiKey: string,
    readonly model: string,
    readonly dimension: number,
  ) {}

  async embed(texts: string[]): Promise<number[][]> {
    if (texts.length === 0) return [];

    const response = await fetch('https://openrouter.ai/api/v1/embeddings', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://ramble.app',
        'X-Title': 'Ramble',
      },
      body: JSON.stringify({ model: this.model, input: texts, dimensions: this.dimension }),
      signal: AbortSignal.timeout(60_000),
    });

    if (!response.ok) {
      throw new Error(
        `OpenRouter embeddings returned ${response.status}: ${(await response.text()).slice(0, 300)}`,
      );
    }

    const body = (await response.json()) as { data: { index: number; embedding: number[] }[] };
    // Results may come back out of order; restore the input order so the
    // caller can zip them against what it sent.
    const ordered = new Array<number[]>(texts.length);
    for (const row of body.data) ordered[row.index] = row.embedding;

    const missing = ordered.findIndex((v) => !v);
    if (missing >= 0) throw new Error(`Embedding provider returned no vector for input ${missing}.`);

    const wrongWidth = ordered.find((v) => v.length !== this.dimension);
    if (wrongWidth) {
      throw new Error(
        `Expected ${this.dimension}-dimensional vectors, got ${wrongWidth.length}. ` +
          'Storing these would silently corrupt search.',
      );
    }
    return ordered;
  }
}

/**
 * Stands in for the device. The server owns chunking either way, so this
 * provider exists to say plainly that the vectors arrive from elsewhere
 * rather than to pretend it can produce them.
 */
class DeviceEmbeddingProvider implements EmbeddingProvider {
  readonly name = 'device';
  readonly mocked = false;

  constructor(readonly model: string, readonly dimension: number) {}

  async embed(): Promise<number[][]> {
    throw new Error('Embeddings for this deployment are computed on the device.');
  }
}

/**
 * Which vector space this deployment is currently building.
 *
 * Two vectors are only comparable if they came from the same model at the same
 * revision. Apple's on-device model and OpenAI's truncated one are both 512
 * wide, so width alone can no longer tell them apart — this is what does.
 */
export interface EmbeddingSpace {
  model: string;
  revision: number;
  dimension: number;
  /** True when the server produces vectors itself rather than awaiting a device. */
  serverEmbeds: boolean;
}

export function activeEmbeddingSpace(): EmbeddingSpace {
  const { provider, model, dimension, deviceRevision } = config.embedding;
  return {
    model,
    revision: deviceRevision,
    dimension,
    serverEmbeds: provider !== 'device',
  };
}

/**
 * A deterministic embedder, for tests and for standing in for a device.
 *
 * Exported because the server's own provider refuses to embed on a device
 * deployment — correctly, since it cannot — which leaves a test simulating a
 * phone with nothing to compute vectors with.
 */
export function createSimulatedDeviceEmbedder(dimension: number): EmbeddingProvider {
  return new MockEmbeddingProvider(dimension);
}

export function createEmbeddingProvider(): EmbeddingProvider {
  const { provider, openaiKey, model, dimension } = config.embedding;

  if (provider === 'device') return new DeviceEmbeddingProvider(model, dimension);
  if (provider === 'openrouter' && config.openrouter.apiKey) {
    return new OpenRouterEmbeddingProvider(config.openrouter.apiKey, model, dimension);
  }
  if (provider === 'openai' && openaiKey) {
    return new OpenAIEmbeddingProvider(openaiKey, model, dimension);
  }
  if (provider !== 'mock') {
    log.warn('embedding.falling_back_to_mock', { requested: provider, reason: 'missing API key' });
  }
  return new MockEmbeddingProvider(dimension);
}
