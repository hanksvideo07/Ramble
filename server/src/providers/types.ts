import type { UnderstandingResult } from './schema.ts';

/**
 * Provider interfaces. Model calls happen only behind these; no route or
 * pipeline stage talks to a vendor SDK directly.
 */

export interface TranscriptSegment {
  index: number;
  startSeconds: number;
  endSeconds: number;
  text: string;
  speaker?: string | null;
}

export interface TranscriptionResult {
  text: string;
  segments: TranscriptSegment[];
  language: string | null;
  confidence: number | null;
  provider: string;
  model: string | null;
  /** True when produced by a stand-in rather than a real provider. */
  mocked: boolean;
}

export interface TranscriptionProvider {
  readonly name: string;
  readonly mocked: boolean;
  transcribe(audio: Buffer, opts: { contentType: string; durationSeconds: number }): Promise<TranscriptionResult>;
}

export interface EmbeddingProvider {
  readonly name: string;
  readonly model: string;
  readonly dimension: number;
  readonly mocked: boolean;
  embed(texts: string[]): Promise<number[][]>;
}

export interface UnderstandingInput {
  transcript: string;
  /** Section summaries for a long ramble; the model synthesizes from these. */
  sectionSummaries?: { topic: string; summary: string }[];
  profile: string;
  recordedAt: Date;
  timezone: string;
  /** Entity names already known for this user, to encourage consistent naming. */
  knownEntities: string[];
}

export interface UnderstandingProvider {
  readonly name: string;
  readonly model: string;
  readonly mocked: boolean;
  readonly promptVersion: string;
  understand(input: UnderstandingInput): Promise<UnderstandingResult>;
}

export interface AnswerCitation {
  rambleId: string;
  rambleTitle: string;
  quote: string;
  recordedAt: string;
  sourceKind: string;
}

export interface AnswerResult {
  answer: string;
  citations: AnswerCitation[];
  mocked: boolean;
}

export interface AnswerProvider {
  readonly name: string;
  readonly mocked: boolean;
  answer(question: string, context: AnswerContextChunk[]): Promise<AnswerResult>;
}

export interface AnswerContextChunk {
  rambleId: string;
  rambleTitle: string;
  recordedAt: string;
  sourceKind: string;
  content: string;
}
