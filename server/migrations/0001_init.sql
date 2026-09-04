-- ===========================================================================
-- Ramble: initial schema
--
-- Design notes:
--   * Every user-owned row carries user_id directly, even when it could be
--     reached through a join. Retrieval paths filter on it explicitly so a
--     missing join condition can never leak across users.
--   * The pipeline is resumable: rambles.processing_state plus the
--     processing_stages table record where a ramble got to and why it stopped.
--   * Audio and raw transcripts are never mutated by later stages.
-- ===========================================================================

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- --- users -----------------------------------------------------------------

CREATE TABLE users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email           text UNIQUE NOT NULL,
  password_hash   text NOT NULL,
  display_name    text,
  -- Drives extraction defaults only; never changes the data model.
  profile         text NOT NULL DEFAULT 'other'
                  CHECK (profile IN ('student','founder','executive','creator','developer','other')),
  settings        jsonb NOT NULL DEFAULT '{}'::jsonb,
  onboarded_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash   text UNIQUE NOT NULL,
  device       text,
  expires_at   timestamptz NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sessions_user_idx ON sessions(user_id);

-- --- rambles ---------------------------------------------------------------

CREATE TABLE rambles (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  -- Supplied by the client at capture time so an offline recording keeps its
  -- true moment, and so retried uploads are idempotent.
  client_id          text NOT NULL,
  recorded_at        timestamptz NOT NULL,
  duration_seconds   double precision NOT NULL DEFAULT 0,
  source_device      text NOT NULL DEFAULT 'ios'
                     CHECK (source_device IN ('ios','watch','action_button','widget','import')),

  title              text,
  summary            text,
  clean_transcript   text,
  language           text,

  processing_state   text NOT NULL DEFAULT 'awaiting_upload'
                     CHECK (processing_state IN (
                       'awaiting_upload','uploaded','transcribing','transcribed',
                       'understanding','embedding','processed','failed'
                     )),
  processing_error   text,
  processed_at       timestamptz,

  -- Only populated when the user has explicitly granted location capture.
  location           jsonb,

  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),

  UNIQUE (user_id, client_id)
);
CREATE INDEX rambles_user_recorded_idx ON rambles(user_id, recorded_at DESC);
CREATE INDEX rambles_state_idx ON rambles(processing_state)
  WHERE processing_state <> 'processed';

-- Per-stage observability. One row per attempt of a stage on a ramble.
CREATE TABLE processing_stages (
  id            bigserial PRIMARY KEY,
  ramble_id     uuid NOT NULL REFERENCES rambles(id) ON DELETE CASCADE,
  stage         text NOT NULL,
  status        text NOT NULL CHECK (status IN ('started','succeeded','failed')),
  attempt       int NOT NULL DEFAULT 1,
  duration_ms   int,
  error         text,
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX processing_stages_ramble_idx ON processing_stages(ramble_id, created_at DESC);

-- --- audio -----------------------------------------------------------------

CREATE TABLE audio_assets (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ramble_id      uuid NOT NULL REFERENCES rambles(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  storage_key    text NOT NULL,
  content_type   text NOT NULL DEFAULT 'audio/m4a',
  byte_size      bigint,
  sample_rate    int,
  checksum       text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audio_assets_ramble_idx ON audio_assets(ramble_id);

-- --- transcripts -----------------------------------------------------------
-- The raw transcript is written once and never edited. Cleaned prose lives on
-- rambles.clean_transcript so the source stays recoverable.

CREATE TABLE transcripts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ramble_id     uuid NOT NULL REFERENCES rambles(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider      text NOT NULL,
  model         text,
  raw_text      text NOT NULL,
  language      text,
  confidence    double precision,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX transcripts_ramble_idx ON transcripts(ramble_id);

CREATE TABLE transcript_segments (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transcript_id  uuid NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
  ramble_id      uuid NOT NULL REFERENCES rambles(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  idx            int NOT NULL,
  start_seconds  double precision NOT NULL,
  end_seconds    double precision NOT NULL,
  text           text NOT NULL,
  speaker        text,
  -- Set once topic segmentation groups segments into sections.
  section_idx    int,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (transcript_id, idx)
);
CREATE INDEX transcript_segments_ramble_idx ON transcript_segments(ramble_id, idx);

-- Section-level summaries for long rambles; the synthesis step reads these
-- instead of the full transcript.
CREATE TABLE transcript_sections (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ramble_id      uuid NOT NULL REFERENCES rambles(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  idx            int NOT NULL,
  start_seconds  double precision NOT NULL,
  end_seconds    double precision NOT NULL,
  topic          text,
  summary        text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (ramble_id, idx)
);

-- --- extracted items -------------------------------------------------------
-- One ramble produces many items of many kinds. Never collapsed to one type.

CREATE TABLE extracted_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ramble_id       uuid NOT NULL REFERENCES rambles(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  kind            text NOT NULL CHECK (kind IN (
                    'summary','note','idea','task','reminder','decision',
                    'question','journal','commitment','follow_up','reference'
                  )),
  title           text NOT NULL,
  body            text,

  -- Kind-specific fields (due_at, url, status...) stay here rather than
  -- forcing a sparse column per kind.
  attributes      jsonb NOT NULL DEFAULT '{}'::jsonb,

  status          text NOT NULL DEFAULT 'open'
                  CHECK (status IN ('open','done','dismissed','archived')),
  confidence      double precision NOT NULL DEFAULT 0.5,

  -- Provenance back into the source recording.
  source_start_seconds  double precision,
  source_end_seconds    double precision,
  source_quote          text,

  -- Set when the user corrects the model ("this isn't a task").
  corrected_by_user  boolean NOT NULL DEFAULT false,
  original_kind      text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX extracted_items_ramble_idx ON extracted_items(ramble_id);
CREATE INDEX extracted_items_user_kind_idx ON extracted_items(user_id, kind, created_at DESC);
CREATE INDEX extracted_items_open_idx ON extracted_items(user_id, kind)
  WHERE status = 'open';

-- --- entities --------------------------------------------------------------
-- Resolution keys off normalized_name so "Sarah" and "Sarah Chen" can be
-- merged deliberately rather than accumulating junk rows.

CREATE TABLE entities (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind              text NOT NULL CHECK (kind IN (
                      'person','organization','project','place','product','topic'
                    )),
  name              text NOT NULL,
  normalized_name   text NOT NULL,
  aliases           text[] NOT NULL DEFAULT '{}',
  overview          text,
  attributes        jsonb NOT NULL DEFAULT '{}'::jsonb,
  mention_count     int NOT NULL DEFAULT 0,
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),

  -- Set when this entity is merged into another; retrieval skips merged rows
  -- but existing mentions stay valid and repoint via merged_into_id.
  merged_into_id    uuid REFERENCES entities(id) ON DELETE SET NULL,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  UNIQUE (user_id, kind, normalized_name)
);
CREATE INDEX entities_user_idx ON entities(user_id, last_seen_at DESC)
  WHERE merged_into_id IS NULL;
CREATE INDEX entities_name_trgm_idx ON entities USING gin (normalized_name gin_trgm_ops);

CREATE TABLE entity_mentions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_id         uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ramble_id         uuid NOT NULL REFERENCES rambles(id) ON DELETE CASCADE,
  extracted_item_id uuid REFERENCES extracted_items(id) ON DELETE CASCADE,
  mention_text      text NOT NULL,
  context           text,
  confidence        double precision NOT NULL DEFAULT 0.5,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX entity_mentions_entity_idx ON entity_mentions(entity_id, created_at DESC);
CREATE INDEX entity_mentions_ramble_idx ON entity_mentions(ramble_id);
CREATE UNIQUE INDEX entity_mentions_dedup_idx
  ON entity_mentions(entity_id, ramble_id, COALESCE(extracted_item_id, '00000000-0000-0000-0000-000000000000'::uuid), mention_text);

CREATE TABLE relationships (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  from_entity_id  uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  to_entity_id    uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  kind            text NOT NULL,
  confidence      double precision NOT NULL DEFAULT 0.5,
  ramble_id       uuid REFERENCES rambles(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (from_entity_id, to_entity_id, kind)
);
CREATE INDEX relationships_user_idx ON relationships(user_id);

-- --- actions ---------------------------------------------------------------
-- Normalized internal actions. The model never names a provider API; it emits
-- a type from this vocabulary and an adapter executes it.

CREATE TABLE actions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ramble_id             uuid NOT NULL REFERENCES rambles(id) ON DELETE CASCADE,
  extracted_item_id     uuid REFERENCES extracted_items(id) ON DELETE SET NULL,

  type                  text NOT NULL,
  parameters            jsonb NOT NULL DEFAULT '{}'::jsonb,

  confidence            double precision NOT NULL DEFAULT 0.5,
  -- information | intention | explicit_action | external_communication
  intent_class          text NOT NULL DEFAULT 'intention'
                        CHECK (intent_class IN (
                          'information','intention','explicit_action','external_communication'
                        )),
  risk                  text NOT NULL DEFAULT 'medium'
                        CHECK (risk IN ('low','medium','high')),
  requires_confirmation boolean NOT NULL DEFAULT true,

  state                 text NOT NULL DEFAULT 'detected'
                        CHECK (state IN (
                          'detected','awaiting_confirmation','approved','executing',
                          'completed','failed','cancelled'
                        )),

  integration_id        uuid,
  result                jsonb,
  error                 text,

  -- Guards against a retried pipeline run executing the same action twice.
  idempotency_key       text,

  confirmed_at          timestamptz,
  executed_at           timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX actions_user_state_idx ON actions(user_id, state, created_at DESC);
CREATE INDEX actions_ramble_idx ON actions(ramble_id);
CREATE UNIQUE INDEX actions_idempotency_idx ON actions(user_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

-- --- integrations ----------------------------------------------------------

CREATE TABLE integrations (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider       text NOT NULL,
  status         text NOT NULL DEFAULT 'connected'
                 CHECK (status IN ('connected','disconnected','error')),
  display_name   text,
  scopes         text[] NOT NULL DEFAULT '{}',
  config         jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_error     text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, provider)
);

-- Tokens live apart from integrations so the row an API returns never carries
-- secrets by accident.
CREATE TABLE integration_credentials (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  integration_id    uuid NOT NULL REFERENCES integrations(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  access_token_enc  text,
  refresh_token_enc text,
  expires_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (integration_id)
);

CREATE TABLE webhooks (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  url            text NOT NULL,
  events         text[] NOT NULL DEFAULT '{}',
  secret         text NOT NULL,
  active         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE webhook_deliveries (
  id             bigserial PRIMARY KEY,
  webhook_id     uuid NOT NULL REFERENCES webhooks(id) ON DELETE CASCADE,
  event          text NOT NULL,
  payload        jsonb NOT NULL,
  status         text NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','delivered','failed')),
  attempts       int NOT NULL DEFAULT 0,
  response_code  int,
  next_attempt_at timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX webhook_deliveries_pending_idx ON webhook_deliveries(next_attempt_at)
  WHERE status = 'pending';

-- --- embeddings ------------------------------------------------------------
-- One row per semantic unit, never one per whole transcript. source_kind says
-- what the vector represents so search can weight and label results.

CREATE TABLE embedding_records (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ramble_id      uuid NOT NULL REFERENCES rambles(id) ON DELETE CASCADE,

  source_kind    text NOT NULL CHECK (source_kind IN (
                   'segment_chunk','section_summary','ramble_summary','extracted_item','entity_overview'
                 )),
  source_id      uuid,
  content        text NOT NULL,
  embedding      vector(1536),

  model          text NOT NULL,
  -- Bumped when chunking or the prompt changes so stale vectors are findable.
  pipeline_version int NOT NULL DEFAULT 1,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX embedding_records_user_idx ON embedding_records(user_id);
CREATE INDEX embedding_records_ramble_idx ON embedding_records(ramble_id);
CREATE INDEX embedding_records_vector_idx ON embedding_records
  USING hnsw (embedding vector_cosine_ops);

-- --- lexical search --------------------------------------------------------
-- Mirrors the same semantic units as embedding_records so hybrid search can
-- fuse two rankings over one comparable set of rows.

CREATE TABLE search_documents (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ramble_id      uuid NOT NULL REFERENCES rambles(id) ON DELETE CASCADE,
  source_kind    text NOT NULL,
  source_id      uuid,
  title          text,
  content        text NOT NULL,
  tsv            tsvector GENERATED ALWAYS AS (
                   setweight(to_tsvector('english', coalesce(title,'')), 'A') ||
                   setweight(to_tsvector('english', coalesce(content,'')), 'B')
                 ) STORED,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX search_documents_tsv_idx ON search_documents USING gin (tsv);
CREATE INDEX search_documents_user_idx ON search_documents(user_id);
CREATE INDEX search_documents_ramble_idx ON search_documents(ramble_id);

-- --- analytics -------------------------------------------------------------

CREATE TABLE analytics_events (
  id           bigserial PRIMARY KEY,
  user_id      uuid REFERENCES users(id) ON DELETE SET NULL,
  name         text NOT NULL,
  properties   jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX analytics_events_name_idx ON analytics_events(name, created_at DESC);

-- --- updated_at maintenance ------------------------------------------------

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_touch BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER rambles_touch BEFORE UPDATE ON rambles
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER extracted_items_touch BEFORE UPDATE ON extracted_items
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER entities_touch BEFORE UPDATE ON entities
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER actions_touch BEFORE UPDATE ON actions
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER integrations_touch BEFORE UPDATE ON integrations
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
