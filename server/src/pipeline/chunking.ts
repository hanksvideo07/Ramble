import type { TranscriptSegment } from '../providers/types.ts';

/**
 * Long rambles are never handed to a model whole. Segments are grouped into
 * sections at natural boundaries, each section is summarized, and the final
 * synthesis reads the summaries rather than the raw transcript.
 */

/** Above this, the transcript is sectioned before understanding. */
export const LONG_TRANSCRIPT_CHARS = 12_000;

/** Target size of one section handed to the model. */
const SECTION_TARGET_CHARS = 6_000;

/** A pause at least this long is treated as a topic boundary. */
const PAUSE_BOUNDARY_SECONDS = 2.5;

export interface Section {
  index: number;
  startSeconds: number;
  endSeconds: number;
  segments: TranscriptSegment[];
  text: string;
}

/**
 * Groups segments into sections, preferring to break at long pauses so a
 * section rarely splits a thought in half. Falls back to a size-based break
 * when someone talks continuously for a long stretch.
 */
export function sectionSegments(segments: TranscriptSegment[]): Section[] {
  if (segments.length === 0) return [];

  const sections: Section[] = [];
  let current: TranscriptSegment[] = [];
  let currentChars = 0;

  const flush = () => {
    if (current.length === 0) return;
    const first = current[0]!;
    const last = current[current.length - 1]!;
    sections.push({
      index: sections.length,
      startSeconds: first.startSeconds,
      endSeconds: last.endSeconds,
      segments: current,
      text: current.map((s) => s.text).join(' '),
    });
    current = [];
    currentChars = 0;
  };

  for (let i = 0; i < segments.length; i += 1) {
    const segment = segments[i]!;
    const previous = segments[i - 1];
    const pause = previous ? segment.startSeconds - previous.endSeconds : 0;

    // Break before this segment if the section is already substantial and we
    // are at a natural pause, or if it has grown past the hard target.
    const bigEnough = currentChars >= SECTION_TARGET_CHARS * 0.6;
    if (current.length > 0 && ((bigEnough && pause >= PAUSE_BOUNDARY_SECONDS) || currentChars >= SECTION_TARGET_CHARS)) {
      flush();
    }

    current.push(segment);
    currentChars += segment.text.length + 1;
  }
  flush();
  return sections;
}

/**
 * Builds the units that get embedded and indexed for search. Chunks follow
 * segment boundaries so a chunk never begins mid-sentence, and overlap by one
 * segment so a thought spanning a boundary is still retrievable.
 */
export interface Chunk {
  startSeconds: number;
  endSeconds: number;
  text: string;
}

const CHUNK_TARGET_CHARS = 1_200;

export function chunkSegments(segments: TranscriptSegment[]): Chunk[] {
  if (segments.length === 0) return [];

  const chunks: Chunk[] = [];
  let current: TranscriptSegment[] = [];
  let currentChars = 0;

  const flush = (carryOverlap: boolean) => {
    if (current.length === 0) return;
    const first = current[0]!;
    const last = current[current.length - 1]!;
    chunks.push({
      startSeconds: first.startSeconds,
      endSeconds: last.endSeconds,
      text: current.map((s) => s.text).join(' '),
    });
    // Carry the last segment into the next chunk as overlap.
    const overlap = carryOverlap ? current.slice(-1) : [];
    current = [...overlap];
    currentChars = overlap.reduce((sum, s) => sum + s.text.length + 1, 0);
  };

  for (const segment of segments) {
    if (currentChars + segment.text.length > CHUNK_TARGET_CHARS && current.length > 0) {
      flush(true);
    }
    current.push(segment);
    currentChars += segment.text.length + 1;
  }
  flush(false);

  return chunks;
}
