import 'dotenv/config';
import { pool, toVectorLiteral } from '../src/db/pool.ts';
import { activeEmbeddingSpace, createEmbeddingProvider } from '../src/providers/embedding.ts';
import { log } from '../src/lib/logger.ts';

/**
 * Fills in vectors the corpus is missing, and replaces any left over from a
 * different model.
 *
 *   npm run embeddings:backfill
 *
 * This is what makes switching embedding providers a real option rather than a
 * config change that quietly empties semantic search. Rows carrying vectors
 * from the old space are not comparable to new queries — search already
 * refuses to mix them — so they are re-embedded rather than left to rot.
 *
 * Safe to run repeatedly and safe to interrupt: it works in batches and only
 * ever writes rows it has just embedded.
 */

const BATCH = 96;

const space = activeEmbeddingSpace();
if (!space.serverEmbeds) {
  console.error(
    'EMBEDDING_PROVIDER is "device", so the server does not embed. ' +
      'Set it to openrouter (or openai) before backfilling.',
  );
  process.exit(1);
}

const provider = createEmbeddingProvider();
console.log(`Backfilling with ${provider.name} (${provider.model}) at ${space.dimension} dims, revision ${space.revision}.\n`);

let done = 0;
let failed = 0;

for (;;) {
  // Anything with no vector, or with one from a space this deployment has
  // moved on from.
  const { rows } = await pool.query<{ id: string; content: string }>(
    `SELECT id, content
       FROM embedding_records
      WHERE embedding IS NULL
         OR model <> $1
         OR model_revision <> $2
      ORDER BY created_at
      LIMIT $3`,
    [space.model, space.revision, BATCH],
  );
  if (rows.length === 0) break;

  let vectors: number[][];
  try {
    vectors = await provider.embed(rows.map((r) => r.content));
  } catch (error) {
    // A failed batch must not spin forever on the same rows.
    failed += rows.length;
    log.error('backfill.batch_failed', {
      count: rows.length,
      error: error instanceof Error ? error.message : String(error),
    });
    break;
  }

  for (let i = 0; i < rows.length; i += 1) {
    const row = rows[i]!;
    const vector = vectors[i];
    if (!vector) continue;
    await pool.query(
      `UPDATE embedding_records
          SET embedding = $2::vector, model = $3, model_revision = $4
        WHERE id = $1`,
      [row.id, toVectorLiteral(vector), space.model, space.revision],
    );
    done += 1;
  }
  process.stdout.write(`\r  ${done} embedded`);
}

console.log(`\n\nDone. ${done} embedded${failed > 0 ? `, ${failed} left after a failed batch` : ''}.`);
await pool.end();
