import { config } from '../lib/config.ts';
import { answerSystemPrompt } from './prompts.ts';
import { chat } from './openrouter.ts';
import type { AnswerContextChunk, AnswerProvider, AnswerResult } from './types.ts';

/** Renders retrieved chunks as numbered excerpts the model can cite by [n]. */
function renderContext(chunks: AnswerContextChunk[]): string {
  return chunks
    .map(
      (chunk, i) =>
        `[${i + 1}] ${chunk.rambleTitle} — ${new Date(chunk.recordedAt).toDateString()} (${chunk.sourceKind})\n${chunk.content}`,
    )
    .join('\n\n');
}

/** Maps the [n] markers the model used back to their source rambles. */
function citationsFor(answer: string, chunks: AnswerContextChunk[]): AnswerResult['citations'] {
  const used = new Set<number>();
  for (const match of answer.matchAll(/\[(\d+)\]/g)) {
    const n = Number.parseInt(match[1] ?? '', 10);
    if (n >= 1 && n <= chunks.length) used.add(n);
  }
  // If the model cited nothing, show the top retrieved chunks so the answer is
  // still inspectable rather than unsourced.
  const indices = used.size > 0 ? [...used].sort((a, b) => a - b) : chunks.slice(0, 3).map((_, i) => i + 1);
  return indices.flatMap((n) => {
    const chunk = chunks[n - 1];
    if (!chunk) return [];
    return [
      {
        rambleId: chunk.rambleId,
        rambleTitle: chunk.rambleTitle,
        quote: chunk.content.slice(0, 300),
        recordedAt: chunk.recordedAt,
        sourceKind: chunk.sourceKind,
      },
    ];
  });
}

class OpenRouterAnswerProvider implements AnswerProvider {
  readonly name = 'openrouter';
  readonly mocked = false;

  constructor(private readonly model: string) {}

  async answer(question: string, chunks: AnswerContextChunk[]): Promise<AnswerResult> {
    if (chunks.length === 0) {
      return {
        answer: "I couldn't find anything in your rambles about that.",
        citations: [],
        mocked: false,
      };
    }

    const text = (
      await chat({
        model: this.model,
        messages: [
          { role: 'system', content: answerSystemPrompt },
          {
            role: 'user',
            content: `EXCERPTS FROM YOUR RECORDINGS\n\n${renderContext(chunks)}\n\nQUESTION\n${question}`,
          },
        ],
        maxTokens: 1500,
        // A little warmth reads better than extraction's determinism, without
        // letting the answer drift from the excerpts.
        temperature: 0.3,
      })
    ).trim();

    return { answer: text, citations: citationsFor(text, chunks), mocked: false };
  }
}

/**
 * Without a key, Ask Ramble still returns real retrieved excerpts — it just
 * doesn't synthesize prose over them. Retrieval quality stays inspectable.
 */
class MockAnswerProvider implements AnswerProvider {
  readonly name = 'mock';
  readonly mocked = true;

  async answer(question: string, chunks: AnswerContextChunk[]): Promise<AnswerResult> {
    if (chunks.length === 0) {
      return {
        answer: "I couldn't find anything in your rambles about that.",
        citations: [],
        mocked: true,
      };
    }
    const lines = chunks
      .slice(0, 5)
      .map((chunk, i) => `[${i + 1}] ${chunk.content.slice(0, 200)}`)
      .join('\n');
    return {
      answer: `Here is what you've said that relates to "${question}":\n\n${lines}\n\n(Set OPENROUTER_API_KEY to get a synthesized answer instead of raw excerpts.)`,
      citations: citationsFor('', chunks),
      mocked: true,
    };
  }
}

export function createAnswerProvider(): AnswerProvider {
  const { apiKey, answerModel } = config.openrouter;
  if (apiKey) return new OpenRouterAnswerProvider(answerModel);
  return new MockAnswerProvider();
}
