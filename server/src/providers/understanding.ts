import Anthropic from '@anthropic-ai/sdk';
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
import type { UnderstandingInput, UnderstandingProvider } from './types.ts';

const TOOL_NAME = 'record_understanding';

class AnthropicUnderstandingProvider implements UnderstandingProvider {
  readonly name = 'anthropic';
  readonly mocked = false;
  readonly promptVersion = UNDERSTANDING_PROMPT_VERSION;
  private readonly client: Anthropic;

  constructor(apiKey: string, readonly model: string) {
    this.client = new Anthropic({ apiKey });
  }

  async understand(input: UnderstandingInput): Promise<UnderstandingResult> {
    // tool_choice forces the structured shape rather than hoping for clean
    // JSON in prose. The result is still validated before anything is written.
    const response = await this.client.messages.create({
      model: this.model,
      max_tokens: 8192,
      system: understandingSystemPrompt(input.profile),
      tools: [
        {
          name: TOOL_NAME,
          description: 'Record the structured understanding of this recording.',
          input_schema: understandingJsonSchema as never,
        },
      ],
      tool_choice: { type: 'tool', name: TOOL_NAME },
      messages: [{ role: 'user', content: understandingUserPrompt(input) }],
    });

    const toolUse = response.content.find(
      (block): block is Anthropic.ToolUseBlock => block.type === 'tool_use',
    );
    if (!toolUse) {
      throw new Error('Understanding model returned no tool_use block.');
    }

    const parsed = understandingResultSchema.safeParse(toolUse.input);
    if (!parsed.success) {
      // Surface the shape problem, never the transcript content.
      throw new Error(
        `Understanding output failed validation: ${parsed.error.issues
          .map((i) => `${i.path.join('.')}: ${i.message}`)
          .join('; ')}`,
      );
    }
    return parsed.data;
  }
}

/**
 * Rule-based stand-in so the pipeline, timeline, actions, and search can all be
 * exercised without an Anthropic key. It recognizes a handful of spoken
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

  /** Capitalized words that are not sentence-initial are treated as names. */
  private guessEntities(transcript: string): UnderstandingResult['entities'] {
    const found = new Map<string, UnderstandingResult['entities'][number]>();
    const pattern = /(?<![.!?]\s)(?<!^)\b([A-Z][a-z]{2,})(?:\s+([A-Z][a-z]{2,}))?/gm;
    for (const match of transcript.matchAll(pattern)) {
      const name = [match[1], match[2]].filter(Boolean).join(' ');
      if (!name || STOP_WORDS.has(name)) continue;
      if (found.has(name)) continue;
      found.set(name, {
        kind: match[2] ? 'person' : 'organization',
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
]);

function truncate(text: string, max: number): string {
  const clean = text.replace(/\s+/g, ' ').trim().replace(/[.!?]+$/, '');
  return clean.length <= max ? clean : `${clean.slice(0, max - 1).trimEnd()}…`;
}

export function createUnderstandingProvider(): UnderstandingProvider {
  const { apiKey, understandingModel } = config.anthropic;
  if (apiKey) return new AnthropicUnderstandingProvider(apiKey, understandingModel);
  log.warn('understanding.falling_back_to_mock', { reason: 'ANTHROPIC_API_KEY not set' });
  return new MockUnderstandingProvider();
}
