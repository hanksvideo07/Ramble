import { config } from '../lib/config.ts';
import { log } from '../lib/logger.ts';
import {
  understandingJsonSchema,
  understandingResultSchema,
  type UnderstandingResult,
} from './schema.ts';
import {
  UNDERSTANDING_PROMPT_VERSION,
  understandingSystemPrompt,
  understandingUserPrompt,
} from './prompts.ts';
import { chat, extractJSON } from './openrouter.ts';
import type { UnderstandingInput, UnderstandingProvider } from './types.ts';

/**
 * Structured extraction through OpenRouter.
 *
 * Any OpenRouter model can be used; the default is chosen for schema
 * adherence and instruction-following rather than size, because the part that
 * matters most here — telling a musing apart from an instruction — is a
 * judgement call, not a knowledge problem.
 *
 * Output is always validated against the real Zod schema. A model that
 * ignores the schema hint fails validation and gets exactly one repair
 * attempt before the stage is failed and retried by the pipeline.
 */
class OpenRouterUnderstandingProvider implements UnderstandingProvider {
  readonly name = 'openrouter';
  readonly mocked = false;
  readonly promptVersion = UNDERSTANDING_PROMPT_VERSION;

  constructor(readonly model: string) {}

  async understand(input: UnderstandingInput): Promise<UnderstandingResult> {
    const system = understandingSystemPrompt(input.profile);
    const user = understandingUserPrompt(input);

    const first = await chat({
      model: this.model,
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: user },
      ],
      jsonSchema: { name: 'record_understanding', schema: understandingJsonSchema },
    });

    const parsed = this.validate(first);
    if (parsed.ok) return parsed.value;

    // One repair attempt, quoting the model's own output back at it. Small
    // models usually miss a required field rather than misunderstand the task,
    // and that is cheap to fix without redoing the reasoning.
    log.warn('understanding.repairing_invalid_output', { model: this.model, issues: parsed.error });

    const repaired = await chat({
      model: this.model,
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: user },
        { role: 'assistant', content: first },
        {
          role: 'user',
          content:
            `That response did not match the required schema:\n${parsed.error}\n\n` +
            'Return the corrected JSON object only. No prose, no code fence.',
        },
      ],
      jsonSchema: { name: 'record_understanding', schema: understandingJsonSchema },
    });

    const second = this.validate(repaired);
    if (second.ok) return second.value;

    throw new Error(`Understanding output failed validation after a repair attempt: ${second.error}`);
  }

  private validate(
    raw: string,
  ): { ok: true; value: UnderstandingResult } | { ok: false; error: string } {
    let json: unknown;
    try {
      json = extractJSON(raw);
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }

    const parsed = understandingResultSchema.safeParse(json);
    if (!parsed.success) {
      // Report the shape problem only, never the transcript content.
      return {
        ok: false,
        error: parsed.error.issues
          .map((i) => `${i.path.join('.') || 'root'}: ${i.message}`)
          .join('; '),
      };
    }
    return { ok: true, value: parsed.data };
  }
}

/**
 * Rule-based stand-in so the pipeline, timeline, actions, and search can all be
 * exercised without an OpenRouter key. It recognizes a handful of spoken
 * patterns; it is not intended to be good, only to be structurally correct.
 */
class MockUnderstandingProvider implements UnderstandingProvider {
  readonly name = 'mock';
  readonly model = 'mock-rules';
  readonly mocked = true;
  readonly promptVersion = `${UNDERSTANDING_PROMPT_VERSION}+mock`;

  async understand(input: UnderstandingInput): Promise<UnderstandingResult> {
    const sentences = input.transcript
      .split(/(?<=[.!?])\s+/)
      .map((s) => s.trim())
      .filter(Boolean);

    const items: UnderstandingResult['items'] = [];
    const actions: UnderstandingResult['actions'] = [];

    for (const sentence of sentences) {
      const lower = sentence.toLowerCase();

      if (/\bremind me\b/.test(lower)) {
        items.push({
          kind: 'reminder',
          title: truncate(sentence, 80),
          body: null,
          confidence: 0.8,
          source_quote: sentence,
          attributes: { due_at: this.guessDate(lower, input.recordedAt) },
        });
        actions.push({
          type: 'reminder.create',
          intent_class: 'explicit_action',
          confidence: 0.8,
          parameters: { title: truncate(sentence, 80), due_at: this.guessDate(lower, input.recordedAt) },
          source_quote: sentence,
        });
      } else if (/\b(calendar|meeting|schedule)\b/.test(lower)) {
        items.push({
          kind: 'commitment',
          title: truncate(sentence, 80),
          body: null,
          confidence: 0.7,
          source_quote: sentence,
          attributes: {},
        });
        actions.push({
          type: 'calendar.create_event',
          intent_class: 'explicit_action',
          confidence: 0.7,
          parameters: { title: truncate(sentence, 60), starts_at: this.guessDate(lower, input.recordedAt) },
          source_quote: sentence,
        });
      } else if (/\b(email|send her|send him|tell her|tell him)\b/.test(lower)) {
        items.push({
          kind: 'task',
          title: truncate(sentence, 80),
          body: null,
          confidence: 0.7,
          source_quote: sentence,
          attributes: {},
        });
        actions.push({
          type: 'email.draft',
          intent_class: 'external_communication',
          confidence: 0.6,
          parameters: { body: sentence },
          source_quote: sentence,
        });
      } else if (/\b(i need to|i should|i have to|i must)\b/.test(lower)) {
        items.push({
          kind: 'task',
          title: truncate(sentence, 80),
          body: null,
          confidence: 0.7,
          source_quote: sentence,
          attributes: {},
        });
      } else if (/\b(i think|we should|idea|maybe we)\b/.test(lower)) {
        items.push({
          kind: 'idea',
          title: truncate(sentence, 80),
          body: null,
          confidence: 0.6,
          source_quote: sentence,
          attributes: {},
        });
      } else if (/\b(decided|decision|we're going to|let's go with)\b/.test(lower)) {
        items.push({
          kind: 'decision',
          title: truncate(sentence, 80),
          body: null,
          confidence: 0.65,
          source_quote: sentence,
          attributes: {},
        });
      } else {
        items.push({
          kind: 'note',
          title: truncate(sentence, 80),
          body: null,
          confidence: 0.4,
          source_quote: sentence,
          attributes: {},
        });
      }
    }

    return {
      title: truncate(sentences[0] ?? 'Untitled ramble', 48),
      summary: sentences.slice(0, 2).join(' ') || 'A short recording.',
      clean_transcript: input.transcript,
      language: 'en',
      items,
      entities: this.guessEntities(input.transcript),
      relationships: [],
      actions,
    };
  }

  /**
   * Runs of capitalized words are treated as names.
   *
   * The whole run is taken greedily so "Sarah Chen" stays one person rather
   * than splitting into "Sarah" and "Chen". A name introduced by "at" or
   * "from" ("talked to Sarah at Nationwide") reads as an organization;
   * anything else reads as a person. This is a stand-in, not real extraction.
   */
  private guessEntities(transcript: string): UnderstandingResult['entities'] {
    const found = new Map<string, UnderstandingResult['entities'][number]>();
    const pattern = /(\b(?:at|from|with|for|to)\s+)?\b([A-Z][a-z]{2,}(?:\s+[A-Z][a-z]{2,})*)/g;

    for (const match of transcript.matchAll(pattern)) {
      const preposition = match[1]?.trim().toLowerCase();
      if (!match[2]) continue;

      // A run can start with a sentence-opening word ("Also I think we should
      // ask Ben"), so trim stop words off each end rather than dropping the
      // whole match.
      let parts = match[2].split(/\s+/);
      while (parts.length > 0 && STOP_WORDS.has(parts[0]!)) parts = parts.slice(1);
      while (parts.length > 0 && STOP_WORDS.has(parts[parts.length - 1]!)) parts = parts.slice(0, -1);
      if (parts.length === 0) continue;

      const name = parts.join(' ');
      if (found.has(name)) continue;

      found.set(name, {
        kind: preposition === 'at' || preposition === 'from' ? 'organization' : 'person',
        name,
        aliases: [],
        context: null,
        confidence: 0.4,
      });
    }
    return [...found.values()].slice(0, 10);
  }

  private guessDate(lower: string, recordedAt: Date): string | undefined {
    const day = 24 * 60 * 60 * 1000;
    if (lower.includes('tomorrow')) {
      const date = new Date(recordedAt.getTime() + day);
      date.setHours(9, 0, 0, 0);
      return date.toISOString();
    }
    if (lower.includes('friday')) {
      const date = new Date(recordedAt.getTime());
      const delta = (5 - date.getDay() + 7) % 7 || 7;
      date.setDate(date.getDate() + delta);
      date.setHours(14, 0, 0, 0);
      return date.toISOString();
    }
    return undefined;
  }
}

// Capitalized words that are never entities. Days and months matter most:
// "Friday" and "Thursday" appear constantly in spoken plans.
const STOP_WORDS = new Set([
  'The', 'They', 'And', 'But', 'Also', 'Oh', 'She', 'His', 'Her', 'Their', 'This', 'That',
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December',
  'Today', 'Tomorrow', 'Yesterday', 'Tonight', 'Morning', 'Afternoon', 'Evening',
  // Verbs and adverbs that commonly open a spoken sentence, which would
  // otherwise be captured as capitalized names.
  'Remind', 'Send', 'Ask', 'Put', 'Call', 'Book', 'Finish', 'Change', 'Make',
  'Take', 'Need', 'Should', 'Maybe', 'Just', 'Then', 'When', 'What', 'Where',
  'Why', 'How', 'Who', 'Here', 'There', 'Some', 'Every', 'Another', 'Both',
]);

function truncate(text: string, max: number): string {
  const clean = text.replace(/\s+/g, ' ').trim().replace(/[.!?]+$/, '');
  return clean.length <= max ? clean : `${clean.slice(0, max - 1).trimEnd()}…`;
}

export function createUnderstandingProvider(): UnderstandingProvider {
  const { apiKey, understandingModel } = config.openrouter;
  if (apiKey) return new OpenRouterUnderstandingProvider(understandingModel);
  log.warn('understanding.falling_back_to_mock', { reason: 'OPENROUTER_API_KEY not set' });
  return new MockUnderstandingProvider();
}
