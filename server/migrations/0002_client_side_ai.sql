-- ===========================================================================
-- On-device transcription and embeddings.
--
-- Two changes:
--   1. A transcript may now arrive from the device, so the server's transcribe
--      stage is skipped when one is already present.
--   2. Embeddings are produced on the device, which means a different vector
--      width and a revision that must be tracked — vectors from two different
--      model revisions are not comparable, and mixing them silently degrades
--      search rather than failing.
-- ===========================================================================

-- Where a transcript came from. 'device' means it was produced on-device and
-- the server should not re-transcribe unless explicitly asked to.
ALTER TABLE transcripts
  ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'server'
  CHECK (origin IN ('server', 'device'));

-- The embedding model's revision, so a bump can be detected and the affected
-- rows re-embedded instead of quietly polluting search results.
ALTER TABLE embedding_records
  ADD COLUMN IF NOT EXISTS model_revision int NOT NULL DEFAULT 0;

-- On-device vectors are a different width from the previous server-side model.
-- Existing vectors cannot be converted, so they are cleared and rebuilt: a
-- NULL embedding is a row waiting to be embedded, which the device picks up.
DROP INDEX IF EXISTS embedding_records_vector_idx;

ALTER TABLE embedding_records
  ALTER COLUMN embedding TYPE vector(512) USING NULL;

CREATE INDEX embedding_records_vector_idx ON embedding_records
  USING hnsw (embedding vector_cosine_ops);

-- Finds the work the device still owes: rows indexed for lexical search but
-- with no vector yet.
CREATE INDEX IF NOT EXISTS embedding_records_pending_idx
  ON embedding_records (user_id, created_at)
  WHERE embedding IS NULL;
