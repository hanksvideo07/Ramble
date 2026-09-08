import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { activeEmbeddingSpace, createEmbeddingProvider } from '../src/providers/embedding.ts';

describe('the embedding space', () => {
  it('names the model and revision every vector must be stamped with', () => {
    // model and revision together are what stop Apple's 512-wide vectors being
    // compared against OpenAI's 512-wide ones. Width alone cannot: they match.
    const space = activeEmbeddingSpace();
    assert.ok(space.model.length > 0);
    assert.equal(typeof space.revision, 'number');
    assert.equal(typeof space.dimension, 'number');
  });

  it('says plainly whether the server embeds or waits for a device', () => {
    const space = activeEmbeddingSpace();
    assert.equal(space.serverEmbeds, process.env.EMBEDDING_PROVIDER !== 'device');
  });

  it('refuses to fabricate a vector on a device deployment', async () => {
    // The device provider exists to say where embeddings come from, not to
    // pretend it can produce them. Returning zeros here would poison search.
    if (activeEmbeddingSpace().serverEmbeds) return;
    const provider = createEmbeddingProvider();
    await assert.rejects(() => provider.embed(['anything']));
  });

  it('produces vectors of the configured width', async () => {
    const space = activeEmbeddingSpace();
    if (!space.serverEmbeds) return;
    const provider = createEmbeddingProvider();
    const [vector] = await provider.embed(['a short sentence']);
    assert.equal(vector?.length, space.dimension);
  });
});
