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

export function createEmbeddingProvider(): EmbeddingProvider {
  const { provider, openaiKey, model, dimension } = config.embedding;
  if (provider === 'openai' && openaiKey) {
    return new OpenAIEmbeddingProvider(openaiKey, model, dimension);
  }
  if (provider !== 'mock') {
    log.warn('embedding.falling_back_to_mock', { requested: provider, reason: 'missing API key' });
  }
  return new MockEmbeddingProvider(dimension);
}
