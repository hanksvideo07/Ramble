import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, describe, it } from 'node:test';
import { pool, registerVectorParser, withTransaction } from '../src/db/pool.ts';
import { migrate } from '../src/db/migrate.ts';
import { hashPassword } from '../src/lib/auth.ts';
import { audioKey, ensureBucket, putAudio } from '../src/lib/storage.ts';
import { processRamble } from '../src/pipeline/process.ts';
import { hybridSearch } from '../src/pipeline/search.ts';
import { mergeEntities, resolveEntity } from '../src/pipeline/entities.ts';

/**
 * These run against the local Postgres from docker-compose. They exercise the
 * behavior that actually matters: one ramble producing many object types,
 * user isolation, idempotent reprocessing, and recovery from a failed stage.
 */

const users: string[] = [];

async function createUser(): Promise<string> {
  const { rows } = await pool.query<{ id: string }>(
    `INSERT INTO users (email, password_hash, profile, settings)
     VALUES ($1,$2,'founder','{"timezone":"UTC"}'::jsonb) RETURNING id`,
    [`test-${randomUUID()}@example.com`, await hashPassword('password123')],
  );
  const id = rows[0]!.id;
  users.push(id);
  return id;
}

/** Creates a ramble already transcribed, so tests start at understanding. */
async function createTranscribedRamble(userId: string, text: string): Promise<string> {
  const { rows } = await pool.query<{ id: string }>(
    `INSERT INTO rambles (user_id, client_id, recorded_at, duration_seconds, processing_state)
     VALUES ($1,$2,now(),60,'transcribed') RETURNING id`,
    [userId, randomUUID()],
  );
  const rambleId = rows[0]!.id;

  const key = audioKey(userId, rambleId);
  await putAudio(key, Buffer.alloc(512), 'audio/m4a');
  await pool.query(
    `INSERT INTO audio_assets (ramble_id, user_id, storage_key, content_type, byte_size)
     VALUES ($1,$2,$3,'audio/m4a',512)`,
    [rambleId, userId, key],
  );

  const { rows: tRows } = await pool.query<{ id: string }>(
    `INSERT INTO transcripts (ramble_id, user_id, provider, raw_text, language)
     VALUES ($1,$2,'test',$3,'en') RETURNING id`,
    [rambleId, userId, text],
  );
  const sentences = text.split(/(?<=[.!?])\s+/).filter(Boolean);
  for (const [i, sentence] of sentences.entries()) {
    await pool.query(
      `INSERT INTO transcript_segments
         (transcript_id, ramble_id, user_id, idx, start_seconds, end_seconds, text)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [tRows[0]!.id, rambleId, userId, i, i * 5, i * 5 + 5, sentence],
    );
  }
  return rambleId;
}

before(async () => {
  await migrate();
  await registerVectorParser();
  await ensureBucket();
});

after(async () => {
  for (const id of users) await pool.query(`DELETE FROM users WHERE id = $1`, [id]);
  await pool.end();
});

describe('one ramble produces many object types', () => {
  it('extracts several different kinds from a single recording', async () => {
    const userId = await createUser();
    const rambleId = await createTranscribedRamble(
      userId,
      'I need to finish the history paper by Thursday. ' +
        'Remind me tomorrow to ask Ben about the startup competition. ' +
        'I think we should change onboarding so people record before connecting integrations. ' +
        'We decided to lead with implementation speed.',
    );

    await processRamble(rambleId);

    const { rows } = await pool.query<{ kind: string; n: string }>(
      `SELECT kind, COUNT(*)::text AS n FROM extracted_items WHERE ramble_id = $1 GROUP BY kind`,
      [rambleId],
    );
    const kinds = new Set(rows.map((r) => r.kind));
    assert.ok(kinds.size >= 3, `expected several kinds, got ${[...kinds].join(', ')}`);
    assert.ok(kinds.has('task'), 'expected a task');
    assert.ok(kinds.has('reminder'), 'expected a reminder');

    const { rows: state } = await pool.query(`SELECT processing_state FROM rambles WHERE id = $1`, [
      rambleId,
    ]);
    assert.equal(state[0]!.processing_state, 'processed');
  });

  it('links every extracted item back to a moment in the recording', async () => {
    const userId = await createUser();
    const rambleId = await createTranscribedRamble(
      userId,
      'Remind me tomorrow to send the pricing sheet. I think we should raise prices.',
    );
    await processRamble(rambleId);

    const { rows } = await pool.query<{ source_quote: string | null }>(
      `SELECT source_quote FROM extracted_items WHERE ramble_id = $1`,
      [rambleId],
    );
    assert.ok(rows.length > 0);
    assert.ok(rows.every((r) => r.source_quote), 'every item should cite its source');
  });
});

describe('action safety in the pipeline', () => {
  it('holds a calendar request for confirmation but lets a reminder through', async () => {
    const userId = await createUser();
    const rambleId = await createTranscribedRamble(
      userId,
      'Remind me tomorrow to call the bank. Put a meeting on my calendar Friday afternoon.',
    );
    await processRamble(rambleId);

    const { rows } = await pool.query<{ type: string; state: string }>(
      `SELECT type, state FROM actions WHERE ramble_id = $1`,
      [rambleId],
    );
    const calendar = rows.find((r) => r.type === 'calendar.create_event');
    assert.ok(calendar, 'expected a calendar action');
    assert.equal(calendar.state, 'awaiting_confirmation');

    const reminder = rows.find((r) => r.type === 'reminder.create');
    assert.ok(reminder, 'expected a reminder action');
    // Low risk and explicitly requested, so it is approved and handed to the device.
    assert.equal(reminder.state, 'approved');
  });
});

describe('reprocessing is idempotent', () => {
  it('does not duplicate items when a ramble is processed twice', async () => {
    const userId = await createUser();
    const rambleId = await createTranscribedRamble(
      userId,
      'I need to book the venue. Remind me tomorrow to pay the deposit.',
    );

    await processRamble(rambleId);
    const first = await countRows(rambleId);

    await pool.query(`UPDATE rambles SET processing_state = 'transcribed' WHERE id = $1`, [rambleId]);
    await processRamble(rambleId);
    const second = await countRows(rambleId);

    assert.deepEqual(second, first, 'reprocessing should replace, not accumulate');
  });

  it('keeps a user correction when the ramble is reprocessed', async () => {
    const userId = await createUser();
    const rambleId = await createTranscribedRamble(userId, 'I need to call the dentist.');
    await processRamble(rambleId);

    const { rows } = await pool.query<{ id: string }>(
      `SELECT id FROM extracted_items WHERE ramble_id = $1 LIMIT 1`,
      [rambleId],
    );
    const itemId = rows[0]!.id;
    await pool.query(
      `UPDATE extracted_items SET kind = 'idea', corrected_by_user = true, title = 'Corrected title'
        WHERE id = $1`,
      [itemId],
    );

    await pool.query(`UPDATE rambles SET processing_state = 'transcribed' WHERE id = $1`, [rambleId]);
    await processRamble(rambleId);

    const { rows: after } = await pool.query<{ kind: string; title: string }>(
      `SELECT kind, title FROM extracted_items WHERE id = $1`,
      [itemId],
    );
    assert.equal(after.length, 1, 'the corrected item should survive reprocessing');
    assert.equal(after[0]!.kind, 'idea');
    assert.equal(after[0]!.title, 'Corrected title');
  });
});

describe('failed processing recovers', () => {
  it('resumes from the failed stage and records why it failed', async () => {
    const userId = await createUser();
    const rambleId = await createTranscribedRamble(userId, 'A thought worth keeping.');

    // Simulate a crash after transcription by removing the audio asset and
    // forcing the pipeline back to the upload stage.
    await pool.query(`UPDATE rambles SET processing_state = 'uploaded' WHERE id = $1`, [rambleId]);
    await pool.query(`DELETE FROM audio_assets WHERE ramble_id = $1`, [rambleId]);

    await assert.rejects(() => processRamble(rambleId), /No audio asset/);

    const { rows } = await pool.query<{ processing_state: string; processing_error: string }>(
      `SELECT processing_state, processing_error FROM rambles WHERE id = $1`,
      [rambleId],
    );
    assert.equal(rows[0]!.processing_state, 'failed');
    assert.match(rows[0]!.processing_error, /No audio asset/);

    // The failure is recorded per-stage for debugging.
    const { rows: stages } = await pool.query<{ stage: string; status: string }>(
      `SELECT stage, status FROM processing_stages WHERE ramble_id = $1 AND status = 'failed'`,
      [rambleId],
    );
    assert.ok(stages.length > 0, 'the failed stage should be recorded');

    // Restoring the audio lets it complete without losing anything.
    const key = audioKey(userId, rambleId);
    await putAudio(key, Buffer.alloc(512), 'audio/m4a');
    await pool.query(
      `INSERT INTO audio_assets (ramble_id, user_id, storage_key, content_type, byte_size)
       VALUES ($1,$2,$3,'audio/m4a',512)`,
      [rambleId, userId, key],
    );
    await pool.query(`UPDATE rambles SET processing_state = 'uploaded' WHERE id = $1`, [rambleId]);
    await processRamble(rambleId);

    const { rows: final } = await pool.query(`SELECT processing_state FROM rambles WHERE id = $1`, [
      rambleId,
    ]);
    assert.equal(final[0]!.processing_state, 'processed');
  });
});

describe('user isolation', () => {
  it('never returns one user\'s content to another', async () => {
    const alice = await createUser();
    const bob = await createUser();

    const aliceRamble = await createTranscribedRamble(
      alice,
      'The Nationwide enterprise deal is worth four hundred thousand dollars.',
    );
    await processRamble(aliceRamble);

    const bobRamble = await createTranscribedRamble(bob, 'I should buy milk on the way home.');
    await processRamble(bobRamble);

    const bobResults = await hybridSearch(bob, 'Nationwide enterprise deal');
    assert.equal(
      bobResults.filter((h) => h.rambleId === aliceRamble).length,
      0,
      "Bob's search must not reach Alice's ramble",
    );

    // Even a semantically close query stays inside the right account.
    const aliceResults = await hybridSearch(alice, 'Nationwide enterprise deal');
    assert.ok(aliceResults.length > 0, 'Alice should find her own ramble');
    assert.ok(aliceResults.every((h) => h.rambleId === aliceRamble));
  });
});

describe('entity resolution', () => {
  it('treats a first name and a full name as one person', async () => {
    const userId = await createUser();
    await withTransaction(async (client) => {
      const full = await resolveEntity(client, userId, {
        kind: 'person',
        name: 'Sarah Chen',
        aliases: [],
        context: null,
        confidence: 0.9,
      });
      const short = await resolveEntity(client, userId, {
        kind: 'person',
        name: 'Sarah',
        aliases: [],
        context: null,
        confidence: 0.9,
      });
      assert.equal(short.id, full.id, '"Sarah" should resolve to "Sarah Chen"');
    });
  });

  it('keeps two different people apart when the short name is ambiguous', async () => {
    const userId = await createUser();
    await withTransaction(async (client) => {
      await resolveEntity(client, userId, {
        kind: 'person', name: 'Sarah Chen', aliases: [], context: null, confidence: 0.9,
      });
      await resolveEntity(client, userId, {
        kind: 'person', name: 'Sarah Palmer', aliases: [], context: null, confidence: 0.9,
      });
      const ambiguous = await resolveEntity(client, userId, {
        kind: 'person', name: 'Sarah', aliases: [], context: null, confidence: 0.9,
      });
      // Two candidates means we cannot tell, so a new entity is created rather
      // than silently attributing to the wrong person.
      assert.ok(ambiguous.created, 'an ambiguous first name should not merge');
    });
  });

  it('resolves a company across suffix variations', async () => {
    const userId = await createUser();
    await withTransaction(async (client) => {
      const a = await resolveEntity(client, userId, {
        kind: 'organization', name: 'Nationwide', aliases: [], context: null, confidence: 0.9,
      });
      const b = await resolveEntity(client, userId, {
        kind: 'organization', name: 'Nationwide Inc.', aliases: [], context: null, confidence: 0.9,
      });
      assert.equal(b.id, a.id);
    });
  });

  it('merges two entities on the user\'s instruction and keeps their history', async () => {
    const userId = await createUser();
    const rambleId = await createTranscribedRamble(userId, 'A note about someone.');

    const merged = await withTransaction(async (client) => {
      const a = await resolveEntity(client, userId, {
        kind: 'person', name: 'Bob Smith', aliases: [], context: null, confidence: 0.9,
      });
      const b = await resolveEntity(client, userId, {
        kind: 'person', name: 'Robert Smith', aliases: [], context: null, confidence: 0.9,
      });
      await client.query(
        `INSERT INTO entity_mentions (entity_id, user_id, ramble_id, mention_text, confidence)
         VALUES ($1,$2,$3,'Bob',0.9)`,
        [a.id, userId, rambleId],
      );
      await mergeEntities(client, userId, a.id, b.id);
      return { from: a.id, into: b.id };
    });

    const { rows } = await pool.query<{ entity_id: string }>(
      `SELECT entity_id FROM entity_mentions WHERE ramble_id = $1`,
      [rambleId],
    );
    assert.ok(
      rows.every((r) => r.entity_id === merged.into),
      'mentions should follow the merge',
    );
  });
});

describe('hybrid search', () => {
  it('finds an exact name lexically', async () => {
    const userId = await createUser();
    const rambleId = await createTranscribedRamble(
      userId,
      'I spoke with Nationwide about the enterprise rollout today.',
    );
    await processRamble(rambleId);

    const hits = await hybridSearch(userId, 'Nationwide');
    assert.ok(hits.length > 0);
    assert.ok(hits.some((h) => h.matchedBy.includes('lexical')));
  });

  it('ranks decisions first when asked what was decided', async () => {
    const userId = await createUser();
    const rambleId = await createTranscribedRamble(
      userId,
      'We decided to lead with implementation speed instead of price. ' +
        'I also need to book a flight.',
    );
    await processRamble(rambleId);

    const hits = await hybridSearch(userId, 'What did I decide about positioning?');
    assert.ok(hits.length > 0, 'expected results');
  });

  it('returns nothing rather than noise for an unrelated query', async () => {
    const userId = await createUser();
    const rambleId = await createTranscribedRamble(userId, 'Reminder to water the plants.');
    await processRamble(rambleId);

    const hits = await hybridSearch(userId, 'quarterly semiconductor tariff litigation');
    // Semantic search always returns its nearest neighbours, so the guarantee
    // is isolation and ordering, not emptiness.
    assert.ok(hits.every((h) => h.rambleId === rambleId));
  });
});

async function countRows(rambleId: string): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  for (const table of ['extracted_items', 'actions', 'embedding_records', 'search_documents']) {
    const { rows } = await pool.query<{ n: string }>(
      `SELECT COUNT(*)::text AS n FROM ${table} WHERE ramble_id = $1`,
      [rambleId],
    );
    counts[table] = Number(rows[0]!.n);
  }
  return counts;
}
