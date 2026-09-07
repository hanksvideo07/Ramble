import { config } from '../lib/config.ts';
import { log } from '../lib/logger.ts';
import type { TranscriptionProvider, TranscriptionResult, TranscriptSegment } from './types.ts';

/**
 * Splits a block of text into pseudo-segments with plausible timings. Used by
 * the mock provider and as a fallback when a real provider returns text with
 * no timing information.
 */
export function segmentByPunctuation(text: string, durationSeconds: number): TranscriptSegment[] {
  const sentences = text
    .split(/(?<=[.!?])\s+/)
    .map((s) => s.trim())
    .filter(Boolean);
  if (sentences.length === 0) return [];

  const totalChars = sentences.reduce((sum, s) => sum + s.length, 0);
  let cursor = 0;
  return sentences.map((sentence, index) => {
    const share = totalChars > 0 ? sentence.length / totalChars : 1 / sentences.length;
    const start = cursor;
    const end = Math.min(durationSeconds, start + share * durationSeconds);
    cursor = end;
    return { index, startSeconds: start, endSeconds: end, text: sentence, speaker: null };
  });
}

/**
 * Returns fixed sample text so the whole pipeline can be exercised end-to-end
 * with no transcription credentials. Everything it produces is flagged
 * mocked:true and surfaced as such in the client.
 */
class MockTranscriptionProvider implements TranscriptionProvider {
  readonly name = 'mock';
  readonly mocked = true;

  async transcribe(
    _audio: Buffer,
    opts: { contentType: string; durationSeconds: number },
  ): Promise<TranscriptionResult> {
    const text =
      'I talked to Sarah at Nationwide today. They seem interested in the enterprise plan, ' +
      'but she needs pricing by Friday. Remind me tomorrow morning to send her the pricing sheet. ' +
      'Also I think we should change the enterprise pitch to emphasize implementation speed. ' +
      'And put a meeting on my calendar Friday afternoon to follow up.';
    return {
      text,
      segments: segmentByPunctuation(text, Math.max(opts.durationSeconds, 1)),
      language: 'en',
      confidence: null,
      provider: 'mock',
      model: null,
      mocked: true,
    };
  }
}

/** Deepgram nova-3: word-level timings, punctuation, long-form audio. */
class DeepgramTranscriptionProvider implements TranscriptionProvider {
  readonly name = 'deepgram';
  readonly mocked = false;
  readonly model = 'nova-3';

  constructor(private readonly apiKey: string) {}

  async transcribe(
    audio: Buffer,
    opts: { contentType: string; durationSeconds: number },
  ): Promise<TranscriptionResult> {
    const params = new URLSearchParams({
      model: this.model,
      punctuate: 'true',
      smart_format: 'true',
      paragraphs: 'true',
      detect_language: 'true',
      utterances: 'true',
    });
    const response = await fetch(`https://api.deepgram.com/v1/listen?${params}`, {
      method: 'POST',
      headers: { Authorization: `Token ${this.apiKey}`, 'Content-Type': opts.contentType },
      body: new Uint8Array(audio),
    });
    if (!response.ok) {
      throw new Error(`Deepgram returned ${response.status}: ${await response.text()}`);
    }
    const body = (await response.json()) as DeepgramResponse;
    const alternative = body.results?.channels?.[0]?.alternatives?.[0];
    if (!alternative) throw new Error('Deepgram returned no alternatives.');

    const segments: TranscriptSegment[] =
      body.results?.utterances?.map((u, index) => ({
        index,
        startSeconds: u.start,
        endSeconds: u.end,
        text: u.transcript,
        speaker: u.speaker != null ? String(u.speaker) : null,
      })) ?? segmentByPunctuation(alternative.transcript, opts.durationSeconds);

    return {
      text: alternative.transcript,
      segments,
      language: body.results?.channels?.[0]?.detected_language ?? null,
      confidence: alternative.confidence ?? null,
      provider: this.name,
      model: this.model,
      mocked: false,
    };
  }
}

/** OpenAI whisper-1 with verbose_json for segment timings. */
class OpenAITranscriptionProvider implements TranscriptionProvider {
  readonly name = 'openai';
  readonly mocked = false;
  readonly model = 'whisper-1';

  constructor(private readonly apiKey: string) {}

  async transcribe(
    audio: Buffer,
    opts: { contentType: string; durationSeconds: number },
  ): Promise<TranscriptionResult> {
    const form = new FormData();
    form.append('file', new Blob([new Uint8Array(audio)], { type: opts.contentType }), 'audio.m4a');
    form.append('model', this.model);
    form.append('response_format', 'verbose_json');
    form.append('timestamp_granularities[]', 'segment');

    const response = await fetch('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${this.apiKey}` },
      body: form,
    });
    if (!response.ok) {
      throw new Error(`OpenAI transcription returned ${response.status}: ${await response.text()}`);
    }
    const body = (await response.json()) as OpenAITranscriptionResponse;

    const segments: TranscriptSegment[] =
      body.segments?.map((s, index) => ({
        index,
        startSeconds: s.start,
        endSeconds: s.end,
        text: s.text.trim(),
        speaker: null,
      })) ?? segmentByPunctuation(body.text, opts.durationSeconds);

    return {
      text: body.text,
      segments,
      language: body.language ?? null,
      confidence: null,
      provider: this.name,
      model: this.model,
      mocked: false,
    };
  }
}

/**
 * Whether the server can transcribe with a real provider rather than a
 * stand-in. Surfaced to the client so the higher-accuracy option is only
 * offered when it would actually do something.
 */
export function isCloudTranscriptionAvailable(): boolean {
  const { provider, deepgramKey, openaiKey } = config.transcription;
  return (
    (provider === 'deepgram' && Boolean(deepgramKey)) ||
    (provider === 'openai' && Boolean(openaiKey))
  );
}

export function createTranscriptionProvider(): TranscriptionProvider {
  const { provider, deepgramKey, openaiKey } = config.transcription;
  if (provider === 'deepgram' && deepgramKey) return new DeepgramTranscriptionProvider(deepgramKey);
  if (provider === 'openai' && openaiKey) return new OpenAITranscriptionProvider(openaiKey);
  if (provider !== 'mock') {
    log.warn('transcription.falling_back_to_mock', { requested: provider, reason: 'missing API key' });
  }
  return new MockTranscriptionProvider();
}

interface DeepgramResponse {
  results?: {
    channels?: { alternatives?: { transcript: string; confidence?: number }[]; detected_language?: string }[];
    utterances?: { start: number; end: number; transcript: string; speaker?: number }[];
  };
}

interface OpenAITranscriptionResponse {
  text: string;
  language?: string;
  segments?: { start: number; end: number; text: string }[];
}
