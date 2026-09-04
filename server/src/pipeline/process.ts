import type pg from 'pg';
import { pool, toVectorLiteral, withTransaction } from '../db/pool.ts';
import { log, timed } from '../lib/logger.ts';
import { getAudio } from '../lib/storage.ts';
import { createEmbeddingProvider } from '../providers/embedding.ts';
import { createTranscriptionProvider } from '../providers/transcription.ts';
import { createUnderstandingProvider } from '../providers/understanding.ts';
import type { UnderstandingResult } from '../providers/schema.ts';
import { decideConfirmation } from '../actions/policy.ts';
import { definitionFor, validateParameters } from '../actions/registry.ts';
import { executeAction } from '../actions/executor.ts';
import { emitWebhook } from '../integrations/webhooks.ts';
import { chunkSegments, LONG_TRANSCRIPT_CHARS, sectionSegments } from './chunking.ts';
import { resolveEntity } from './entities.ts';

const transcription = createTranscriptionProvider();
const embedding = createEmbeddingProvider();
const understanding = createUnderstandingProvider();

export const PIPELINE_VERSION = 1;

/**
 * Stages run in order, each recording its own outcome. A ramble that fails at
 * embedding keeps its transcript and extracted items; re-running resumes from
 * the failed stage rather than starting over, and nothing already written is
 * duplicated.
 */
type Stage = 'transcribe' | 'understand' | 'embed';

const STAGE_ORDER: Record<Stage, string[]> = {
  // States from which this stage still needs to run.
  transcribe: ['uploaded', 'transcribing', 'failed'],
  understand: ['transcribed', 'understanding', 'failed'],
  embed: ['embedding', 'failed'],
};

export interface ProcessOptions {
  /** Re-run every stage even if it already succeeded. */
  force?: boolean;
}

export async function processRamble(rambleId: string, options: ProcessOptions = {}): Promise<void> {
  const ramble = await loadRamble(rambleId);
  if (!ramble) {
    log.warn('pipeline.ramble_missing', { ramble_id: rambleId });
    return;
  }

  try {
    if (options.force || needsStage(ramble.processing_state, 'transcribe')) {
      await runStage(rambleId, 'transcribe', () => transcribeStage(ramble));
    }
    if (options.force || needsStage(await currentState(rambleId), 'understand')) {
      await runStage(rambleId, 'understand', () => understandStage(rambleId));
    }
    if (options.force || needsStage(await currentState(rambleId), 'embed')) {
      await runStage(rambleId, 'embed', () => embedStage(rambleId));
    }

    await pool.query(
      `UPDATE rambles
          SET processing_state = 'processed', processed_at = now(), processing_error = NULL
        WHERE id = $1`,
      [rambleId],
    );
    await emitWebhook(ramble.user_id, 'ramble.processed', { ramble_id: rambleId });
    log.info('pipeline.completed', { ramble_id: rambleId });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await pool.query(
      `UPDATE rambles SET processing_state = 'failed', processing_error = $2 WHERE id = $1`,
      [rambleId, message],
    );
    log.error('pipeline.failed', { ramble_id: rambleId, error: message });
    throw error;
  }
}

function needsStage(state: string, stage: Stage): boolean {
  return STAGE_ORDER[stage].includes(state);
}

async function currentState(rambleId: string): Promise<string> {
  const { rows } = await pool.query<{ processing_state: string }>(
    `SELECT processing_state FROM rambles WHERE id = $1`,
    [rambleId],
  );
  return rows[0]?.processing_state ?? 'failed';
}

/** Wraps a stage with its own timing, state transition, and failure record. */
async function runStage(rambleId: string, stage: Stage, fn: () => Promise<void>): Promise<void> {
  const attempt = await nextAttempt(rambleId, stage);
  const started = Date.now();
  await pool.query(
    `INSERT INTO processing_stages (ramble_id, stage, status, attempt) VALUES ($1, $2, 'started', $3)`,
    [rambleId, stage, attempt],
  );
  try {
    await fn();
    await pool.query(
      `INSERT INTO processing_stages (ramble_id, stage, status, attempt, duration_ms)
       VALUES ($1, $2, 'succeeded', $3, $4)`,
      [rambleId, stage, attempt, Date.now() - started],
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await pool.query(
      `INSERT INTO processing_stages (ramble_id, stage, status, attempt, duration_ms, error)
       VALUES ($1, $2, 'failed', $3, $4, $5)`,
      [rambleId, stage, attempt, Date.now() - started, message],
    );
    throw error;
  }
}

async function nextAttempt(rambleId: string, stage: Stage): Promise<number> {
  const { rows } = await pool.query<{ attempt: number }>(
    `SELECT COALESCE(MAX(attempt), 0) + 1 AS attempt
       FROM processing_stages WHERE ramble_id = $1 AND stage = $2`,
    [rambleId, stage],
  );
  return rows[0]?.attempt ?? 1;
}

// --- stage: transcribe -----------------------------------------------------

interface RambleRow {
  id: string;
  user_id: string;
  duration_seconds: number;
  recorded_at: Date;
  processing_state: string;
}

async function loadRamble(rambleId: string): Promise<RambleRow | null> {
  const { rows } = await pool.query<RambleRow>(
    `SELECT id, user_id, duration_seconds, recorded_at, processing_state
       FROM rambles WHERE id = $1`,
    [rambleId],
  );
  return rows[0] ?? null;
}

async function transcribeStage(ramble: RambleRow): Promise<void> {
  await pool.query(`UPDATE rambles SET processing_state = 'transcribing' WHERE id = $1`, [ramble.id]);

  const { rows: assets } = await pool.query<{ storage_key: string; content_type: string }>(
    `SELECT storage_key, content_type FROM audio_assets WHERE ramble_id = $1 ORDER BY created_at LIMIT 1`,
    [ramble.id],
  );
  const asset = assets[0];
  if (!asset) throw new Error('No audio asset for this ramble.');

  const audio = await getAudio(asset.storage_key);
  const result = await timed('transcription.latency', { ramble_id: ramble.id }, () =>
    transcription.transcribe(audio, {
      contentType: asset.content_type,
      durationSeconds: ramble.duration_seconds,
    }),
  );

  await withTransaction(async (client) => {
    // Re-running transcription replaces the prior attempt rather than
    // accumulating duplicates.
    await client.query(`DELETE FROM transcripts WHERE ramble_id = $1`, [ramble.id]);

    const { rows } = await client.query<{ id: string }>(
      `INSERT INTO transcripts (ramble_id, user_id, provider, model, raw_text, language, confidence)
       VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id`,
      [
        ramble.id,
        ramble.user_id,
        result.provider,
        result.model,
        result.text,
        result.language,
        result.confidence,
      ],
    );
    const transcriptId = rows[0]!.id;

    for (const segment of result.segments) {
      await client.query(
        `INSERT INTO transcript_segments
           (transcript_id, ramble_id, user_id, idx, start_seconds, end_seconds, text, speaker)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
        [
          transcriptId,
          ramble.id,
          ramble.user_id,
          segment.index,
          segment.startSeconds,
          segment.endSeconds,
          segment.text,
          segment.speaker ?? null,
        ],
      );
    }

    await client.query(
      `UPDATE rambles SET processing_state = 'transcribed', language = $2 WHERE id = $1`,
      [ramble.id, result.language],
    );
  });

  await emitWebhook(ramble.user_id, 'ramble.transcribed', {
    ramble_id: ramble.id,
    mocked: result.mocked,
  });
}

// --- stage: understand -----------------------------------------------------

async function understandStage(rambleId: string): Promise<void> {
  await pool.query(`UPDATE rambles SET processing_state = 'understanding' WHERE id = $1`, [rambleId]);

  const { rows: rambleRows } = await pool.query<{
    user_id: string;
    recorded_at: Date;
    profile: string;
    settings: Record<string, unknown>;
  }>(
    `SELECT r.user_id, r.recorded_at, u.profile, u.settings
       FROM rambles r JOIN users u ON u.id = r.user_id
      WHERE r.id = $1`,
    [rambleId],
  );
  const meta = rambleRows[0];
  if (!meta) throw new Error('Ramble disappeared mid-processing.');

  const { rows: transcriptRows } = await pool.query<{ id: string; raw_text: string }>(
    `SELECT id, raw_text FROM transcripts WHERE ramble_id = $1 ORDER BY created_at DESC LIMIT 1`,
    [rambleId],
  );
  const transcript = transcriptRows[0];
  if (!transcript) throw new Error('No transcript to understand.');

  const { rows: segments } = await pool.query<{
    idx: number;
    start_seconds: number;
    end_seconds: number;
    text: string;
  }>(
    `SELECT idx, start_seconds, end_seconds, text
       FROM transcript_segments WHERE transcript_id = $1 ORDER BY idx`,
    [transcript.id],
  );

  const asSegments = segments.map((s) => ({
    index: s.idx,
    startSeconds: s.start_seconds,
    endSeconds: s.end_seconds,
    text: s.text,
  }));

  // Long rambles get sectioned and summarized first so the final synthesis
  // never receives an arbitrarily large transcript.
  let sectionSummaries: { topic: string; summary: string }[] | undefined;
  if (transcript.raw_text.length > LONG_TRANSCRIPT_CHARS) {
    sectionSummaries = await buildSections(rambleId, meta.user_id, asSegments, meta);
  }

  const { rows: knownEntityRows } = await pool.query<{ name: string }>(
    `SELECT name FROM entities
      WHERE user_id = $1 AND merged_into_id IS NULL
      ORDER BY last_seen_at DESC LIMIT 60`,
    [meta.user_id],
  );

  const result = await timed('understanding.latency', { ramble_id: rambleId }, () =>
    understanding.understand({
      transcript: transcript.raw_text,
      sectionSummaries,
      profile: meta.profile,
      recordedAt: meta.recorded_at,
      timezone: String(meta.settings?.timezone ?? 'UTC'),
      knownEntities: knownEntityRows.map((r) => r.name),
    }),
  );

  await persistUnderstanding(rambleId, meta.user_id, result, asSegments, meta.settings);
  await pool.query(`UPDATE rambles SET processing_state = 'embedding' WHERE id = $1`, [rambleId]);
}

async function buildSections(
  rambleId: string,
  userId: string,
  segments: { index: number; startSeconds: number; endSeconds: number; text: string }[],
  meta: { recorded_at: Date; profile: string; settings: Record<string, unknown> },
): Promise<{ topic: string; summary: string }[]> {
  const sections = sectionSegments(segments);
  await pool.query(`DELETE FROM transcript_sections WHERE ramble_id = $1`, [rambleId]);

  const summaries: { topic: string; summary: string }[] = [];
  for (const section of sections) {
    // Each section is understood on its own; only its title and summary carry
    // forward into the synthesis pass.
    const partial = await understanding.understand({
      transcript: section.text,
      profile: meta.profile,
      recordedAt: meta.recorded_at,
      timezone: String(meta.settings?.timezone ?? 'UTC'),
      knownEntities: [],
    });
    summaries.push({ topic: partial.title, summary: partial.summary });
    await pool.query(
      `INSERT INTO transcript_sections (ramble_id, user_id, idx, start_seconds, end_seconds, topic, summary)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [rambleId, userId, section.index, section.startSeconds, section.endSeconds, partial.title, partial.summary],
    );
  }
  return summaries;
}

/** Locates a quote in the transcript so an item links back to a moment in the audio. */
function locateQuote(
  quote: string | null | undefined,
  segments: { startSeconds: number; endSeconds: number; text: string }[],
): { start: number | null; end: number | null } {
  if (!quote) return { start: null, end: null };
  const needle = quote.toLowerCase().replace(/\s+/g, ' ').trim();
  for (const segment of segments) {
    const haystack = segment.text.toLowerCase().replace(/\s+/g, ' ');
    if (haystack.includes(needle) || needle.includes(haystack)) {
      return { start: segment.startSeconds, end: segment.endSeconds };
    }
  }
  return { start: null, end: null };
}

async function persistUnderstanding(
  rambleId: string,
  userId: string,
  result: UnderstandingResult,
  segments: { startSeconds: number; endSeconds: number; text: string }[],
  settings: Record<string, unknown>,
): Promise<void> {
  const autoApprove = (settings?.auto_approve ?? {}) as Record<string, boolean>;

  const detectedActions = await withTransaction(async (client) => {
    // Re-running understanding replaces machine-generated rows, but never
    // touches items the user has corrected or actions already executed.
    await client.query(
      `DELETE FROM extracted_items
        WHERE ramble_id = $1 AND corrected_by_user = false
          AND attributes->>'created_by' IS DISTINCT FROM 'action'`,
      [rambleId],
    );
    await client.query(
      `DELETE FROM actions
        WHERE ramble_id = $1 AND state IN ('detected','awaiting_confirmation')`,
      [rambleId],
    );

    await client.query(
      `UPDATE rambles SET title = $2, summary = $3, clean_transcript = $4 WHERE id = $1`,
      [rambleId, result.title, result.summary, result.clean_transcript ?? null],
    );

    const itemIdByQuote = new Map<string, string>();
    for (const item of result.items) {
      const location = locateQuote(item.source_quote, segments);
      const { rows } = await client.query<{ id: string }>(
        `INSERT INTO extracted_items
           (ramble_id, user_id, kind, title, body, attributes, confidence,
            source_start_seconds, source_end_seconds, source_quote)
         VALUES ($1,$2,$3,$4,$5,$6::jsonb,$7,$8,$9,$10)
         RETURNING id`,
        [
          rambleId,
          userId,
          item.kind,
          item.title,
          item.body ?? null,
          JSON.stringify(item.attributes ?? {}),
          item.confidence,
          location.start,
          location.end,
          item.source_quote ?? null,
        ],
      );
      if (item.source_quote) itemIdByQuote.set(item.source_quote, rows[0]!.id);
    }

    // Entities resolve against the user's existing graph before mentions land.
    const entityIdByName = new Map<string, string>();
    for (const entity of result.entities) {
      try {
        const resolved = await resolveEntity(client, userId, entity);
        entityIdByName.set(entity.name.toLowerCase(), resolved.id);
        for (const alias of entity.aliases) entityIdByName.set(alias.toLowerCase(), resolved.id);
        await client.query(
          `INSERT INTO entity_mentions (entity_id, user_id, ramble_id, mention_text, context, confidence)
           VALUES ($1,$2,$3,$4,$5,$6)
           ON CONFLICT DO NOTHING`,
          [resolved.id, userId, rambleId, entity.name, entity.context ?? null, entity.confidence],
        );
      } catch (error) {
        // One unusable entity should not cost the ramble its other results.
        log.warn('pipeline.entity_skipped', {
          ramble_id: rambleId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    for (const relationship of result.relationships) {
      const fromId = entityIdByName.get(relationship.from.toLowerCase());
      const toId = entityIdByName.get(relationship.to.toLowerCase());
      if (!fromId || !toId || fromId === toId) continue;
      await client.query(
        `INSERT INTO relationships (user_id, from_entity_id, to_entity_id, kind, confidence, ramble_id)
         VALUES ($1,$2,$3,$4,$5,$6)
         ON CONFLICT (from_entity_id, to_entity_id, kind) DO NOTHING`,
        [userId, fromId, toId, relationship.kind, relationship.confidence, rambleId],
      );
    }

    const created: { id: string; requiresConfirmation: boolean }[] = [];
    for (const action of result.actions) {
      const definition = definitionFor(action.type);
      if (!definition) continue;

      const validated = validateParameters(action.type, action.parameters);
      const decision = decideConfirmation({
        type: action.type,
        intentClass: action.intent_class,
        confidence: action.confidence,
        autoApprove,
      });

      // A malformed action is recorded as failed so the user can see what was
      // heard and why nothing happened, instead of it silently vanishing.
      const state = !validated.ok
        ? 'failed'
        : decision.requiresConfirmation
          ? 'awaiting_confirmation'
          : 'approved';

      const { rows } = await client.query<{ id: string }>(
        `INSERT INTO actions
           (user_id, ramble_id, extracted_item_id, type, parameters, confidence,
            intent_class, risk, requires_confirmation, state, error, idempotency_key)
         VALUES ($1,$2,$3,$4,$5::jsonb,$6,$7,$8,$9,$10,$11,$12)
         ON CONFLICT (user_id, idempotency_key) WHERE idempotency_key IS NOT NULL
           DO NOTHING
         RETURNING id`,
        [
          userId,
          rambleId,
          action.source_quote ? (itemIdByQuote.get(action.source_quote) ?? null) : null,
          action.type,
          JSON.stringify(validated.ok ? validated.value : action.parameters),
          action.confidence,
          action.intent_class,
          decision.risk,
          decision.requiresConfirmation,
          state,
          validated.ok ? null : validated.error,
          `${rambleId}:${action.type}:${action.source_quote ?? ''}`.slice(0, 200),
        ],
      );
      const id = rows[0]?.id;
      if (id && state === 'approved') created.push({ id, requiresConfirmation: false });
    }
    return created;
  });

  await emitWebhook(userId, 'action.requested', { ramble_id: rambleId, count: detectedActions.length });

  // Auto-approved server-side actions run after the transaction commits, so a
  // slow or failing integration cannot roll back the extraction.
  for (const action of detectedActions) {
    const { rows } = await pool.query(
      `SELECT id, user_id, ramble_id, type, parameters, state, requires_confirmation
         FROM actions WHERE id = $1`,
      [action.id],
    );
    if (rows[0]) await executeAction(rows[0] as never);
  }
}

// --- stage: embed ----------------------------------------------------------

/**
 * Builds one searchable unit per semantic thing — transcript chunks, section
 * summaries, the ramble summary, and each extracted item — rather than one
 * vector for the whole recording.
 */
async function embedStage(rambleId: string): Promise<void> {
  const { rows: meta } = await pool.query<{ user_id: string; title: string | null; summary: string | null }>(
    `SELECT user_id, title, summary FROM rambles WHERE id = $1`,
    [rambleId],
  );
  const ramble = meta[0];
  if (!ramble) throw new Error('Ramble disappeared before embedding.');

  const units: { kind: string; sourceId: string | null; title: string | null; content: string }[] = [];

  const { rows: segments } = await pool.query<{ start_seconds: number; end_seconds: number; text: string; idx: number }>(
    `SELECT s.idx, s.start_seconds, s.end_seconds, s.text
       FROM transcript_segments s
       JOIN transcripts t ON t.id = s.transcript_id
      WHERE s.ramble_id = $1
      ORDER BY t.created_at DESC, s.idx`,
    [rambleId],
  );
  for (const chunk of chunkSegments(
    segments.map((s) => ({ index: s.idx, startSeconds: s.start_seconds, endSeconds: s.end_seconds, text: s.text })),
  )) {
    units.push({ kind: 'segment_chunk', sourceId: null, title: ramble.title, content: chunk.text });
  }

  const { rows: sections } = await pool.query<{ id: string; topic: string | null; summary: string | null }>(
    `SELECT id, topic, summary FROM transcript_sections WHERE ramble_id = $1 ORDER BY idx`,
    [rambleId],
  );
  for (const section of sections) {
    if (!section.summary) continue;
    units.push({
      kind: 'section_summary',
      sourceId: section.id,
      title: section.topic,
      content: `${section.topic ?? ''}: ${section.summary}`,
    });
  }

  if (ramble.summary) {
    units.push({ kind: 'ramble_summary', sourceId: null, title: ramble.title, content: ramble.summary });
  }

  const { rows: items } = await pool.query<{ id: string; kind: string; title: string; body: string | null }>(
    `SELECT id, kind, title, body FROM extracted_items WHERE ramble_id = $1`,
    [rambleId],
  );
  for (const item of items) {
    units.push({
      kind: 'extracted_item',
      sourceId: item.id,
      title: item.title,
      content: `${item.kind}: ${item.title}${item.body ? `\n${item.body}` : ''}`,
    });
  }

  if (units.length === 0) return;

  const vectors = await timed('embedding.latency', { ramble_id: rambleId, units: units.length }, () =>
    embedding.embed(units.map((u) => u.content)),
  );

  await withTransaction(async (client) => {
    // Rebuild this ramble's index wholesale so re-processing never leaves
    // stale vectors behind alongside the new ones.
    await client.query(`DELETE FROM embedding_records WHERE ramble_id = $1`, [rambleId]);
    await client.query(`DELETE FROM search_documents WHERE ramble_id = $1`, [rambleId]);

    for (let i = 0; i < units.length; i += 1) {
      const unit = units[i]!;
      const vector = vectors[i];
      if (vector) {
        await client.query(
          `INSERT INTO embedding_records
             (user_id, ramble_id, source_kind, source_id, content, embedding, model, pipeline_version)
           VALUES ($1,$2,$3,$4,$5,$6::vector,$7,$8)`,
          [
            ramble.user_id,
            rambleId,
            unit.kind,
            unit.sourceId,
            unit.content,
            toVectorLiteral(vector),
            embedding.model,
            PIPELINE_VERSION,
          ],
        );
      }
      await client.query(
        `INSERT INTO search_documents (user_id, ramble_id, source_kind, source_id, title, content)
         VALUES ($1,$2,$3,$4,$5,$6)`,
        [ramble.user_id, rambleId, unit.kind, unit.sourceId, unit.title, unit.content],
      );
    }
  });
}

/** Re-embeds an entity overview so entity pages are semantically searchable. */
export async function indexEntityOverview(
  client: pg.PoolClient,
  userId: string,
  entityId: string,
  name: string,
  overview: string,
): Promise<void> {
  const [vector] = await embedding.embed([`${name}: ${overview}`]);
  if (!vector) return;
  await client.query(
    `DELETE FROM embedding_records WHERE source_kind = 'entity_overview' AND source_id = $1`,
    [entityId],
  );
  await client.query(
    `INSERT INTO embedding_records
       (user_id, ramble_id, source_kind, source_id, content, embedding, model, pipeline_version)
     SELECT $1, r.id, 'entity_overview', $2, $3, $4::vector, $5, $6
       FROM rambles r
      WHERE r.user_id = $1
      ORDER BY r.recorded_at DESC LIMIT 1`,
    [userId, entityId, `${name}: ${overview}`, toVectorLiteral(vector), embedding.model, PIPELINE_VERSION],
  );
}

export { embedding, transcription, understanding };
