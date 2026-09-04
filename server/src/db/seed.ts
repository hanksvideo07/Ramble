import { randomUUID } from 'node:crypto';
import { pool, registerVectorParser } from './pool.ts';
import { migrate } from './migrate.ts';
import { hashPassword } from '../lib/auth.ts';
import { audioKey, ensureBucket, putAudio } from '../lib/storage.ts';
import { log } from '../lib/logger.ts';
import { processRamble } from '../pipeline/process.ts';

/**
 * Seeds a demo account whose first ramble shows the whole product at once:
 * one recording becoming a task, an idea, a reminder, a calendar request, and
 * two entities. This is what a new user sees before recording anything.
 */

const DEMO_EMAIL = 'demo@ramble.app';
const DEMO_PASSWORD = 'rambledemo';

const DEMO_RAMBLES = [
  {
    daysAgo: 0,
    minutesAgo: 18,
    duration: 47,
    transcript:
      'I need to finish the history paper by Thursday. Also remind me tomorrow to ask Ben about ' +
      'the startup competition. I have been thinking we should change Ramble onboarding so people ' +
      'actually make their first recording before connecting integrations. Oh, and put practice on ' +
      'my calendar Wednesday at four.',
  },
  {
    daysAgo: 1,
    minutesAgo: 0,
    duration: 92,
    transcript:
      'I talked to Sarah at Nationwide today. They seem interested in the enterprise plan, but she ' +
      'needs pricing by Friday. Remind me tomorrow morning to send her the pricing sheet. Also I ' +
      'think we should change the enterprise pitch to emphasize implementation speed. And put a ' +
      'meeting on my calendar Friday afternoon to follow up.',
  },
  {
    daysAgo: 4,
    minutesAgo: 0,
    duration: 63,
    transcript:
      'Sarah Chen sent over the implementation questions from Nationwide. We decided to lead with ' +
      'implementation speed rather than price. I should put together a one-pager on how fast a ' +
      'typical rollout goes. Their security team also wants to know where the data lives.',
  },
];

/**
 * Silent AAC-ish placeholder. The mock transcription provider ignores the
 * bytes, but a real asset must exist so the upload and playback paths are
 * exercised exactly as they are in production.
 */
function placeholderAudio(): Buffer {
  return Buffer.alloc(2048);
}

async function seed(): Promise<void> {
  await migrate();
  await registerVectorParser();
  await ensureBucket();

  const { rows: existing } = await pool.query<{ id: string }>(
    `SELECT id FROM users WHERE email = $1`,
    [DEMO_EMAIL],
  );
  if (existing[0]) {
    log.info('seed.resetting_demo_user', { user_id: existing[0].id });
    await pool.query(`DELETE FROM users WHERE id = $1`, [existing[0].id]);
  }

  const { rows } = await pool.query<{ id: string }>(
    `INSERT INTO users (email, password_hash, display_name, profile, onboarded_at, settings)
     VALUES ($1,$2,'Demo','founder', now(), '{"timezone":"America/New_York"}'::jsonb)
     RETURNING id`,
    [DEMO_EMAIL, await hashPassword(DEMO_PASSWORD)],
  );
  const userId = rows[0]!.id;

  for (const demo of DEMO_RAMBLES) {
    const recordedAt = new Date(
      Date.now() - demo.daysAgo * 86_400_000 - demo.minutesAgo * 60_000,
    );
    const clientId = randomUUID();

    const { rows: rambleRows } = await pool.query<{ id: string }>(
      `INSERT INTO rambles (user_id, client_id, recorded_at, duration_seconds, source_device, processing_state)
       VALUES ($1,$2,$3,$4,'ios','uploaded') RETURNING id`,
      [userId, clientId, recordedAt, demo.duration],
    );
    const rambleId = rambleRows[0]!.id;

    const key = audioKey(userId, rambleId);
    await putAudio(key, placeholderAudio(), 'audio/m4a');
    await pool.query(
      `INSERT INTO audio_assets (ramble_id, user_id, storage_key, content_type, byte_size)
       VALUES ($1,$2,$3,'audio/m4a',$4)`,
      [rambleId, userId, key, 2048],
    );

    // The mock transcriber returns fixed text, so the seeded transcript is
    // written directly and transcription is marked done. Understanding,
    // entity resolution, and embedding then run for real.
    await seedTranscript(rambleId, userId, demo.transcript, demo.duration);
    await processRamble(rambleId);
    log.info('seed.ramble_processed', { ramble_id: rambleId });
  }

  console.log(`\nSeeded demo account:\n  email:    ${DEMO_EMAIL}\n  password: ${DEMO_PASSWORD}\n`);
}

async function seedTranscript(
  rambleId: string,
  userId: string,
  text: string,
  duration: number,
): Promise<void> {
  const { rows } = await pool.query<{ id: string }>(
    `INSERT INTO transcripts (ramble_id, user_id, provider, model, raw_text, language)
     VALUES ($1,$2,'seed',NULL,$3,'en') RETURNING id`,
    [rambleId, userId, text],
  );
  const transcriptId = rows[0]!.id;

  const sentences = text.split(/(?<=[.!?])\s+/).filter(Boolean);
  const totalChars = sentences.reduce((n, s) => n + s.length, 0);
  let cursor = 0;
  for (const [index, sentence] of sentences.entries()) {
    const span = (sentence.length / totalChars) * duration;
    await pool.query(
      `INSERT INTO transcript_segments
         (transcript_id, ramble_id, user_id, idx, start_seconds, end_seconds, text)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [transcriptId, rambleId, userId, index, cursor, cursor + span, sentence],
    );
    cursor += span;
  }
  await pool.query(`UPDATE rambles SET processing_state = 'transcribed' WHERE id = $1`, [rambleId]);
}

seed()
  .then(() => pool.end())
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
