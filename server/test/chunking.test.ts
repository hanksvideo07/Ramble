import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { chunkSegments, sectionSegments } from '../src/pipeline/chunking.ts';
import { segmentByPunctuation } from '../src/providers/transcription.ts';

function makeSegments(count: number, textLength = 200, gap = 0.1) {
  return Array.from({ length: count }, (_, i) => ({
    index: i,
    startSeconds: i * (5 + gap),
    endSeconds: i * (5 + gap) + 5,
    text: `${'word '.repeat(Math.floor(textLength / 5))}sentence ${i}.`,
    speaker: null,
  }));
}

describe('transcript chunking', () => {
  it('returns nothing for an empty transcript', () => {
    assert.deepEqual(chunkSegments([]), []);
    assert.deepEqual(sectionSegments([]), []);
  });

  it('keeps a short ramble as a single chunk', () => {
    const chunks = chunkSegments(makeSegments(2, 100));
    assert.equal(chunks.length, 1);
  });

  it('splits a long transcript into multiple chunks', () => {
    const chunks = chunkSegments(makeSegments(40, 200));
    assert.ok(chunks.length > 1, 'expected a long transcript to be split');
  });

  it('overlaps chunks so a thought spanning a boundary stays findable', () => {
    const chunks = chunkSegments(makeSegments(40, 200));
    const [first, second] = chunks;
    assert.ok(first && second);
    // The last segment of one chunk reappears at the start of the next.
    assert.ok(second.startSeconds <= first.endSeconds);
  });

  it('never loses the beginning or end of the recording', () => {
    const segments = makeSegments(30, 200);
    const chunks = chunkSegments(segments);
    assert.equal(chunks[0]!.startSeconds, segments[0]!.startSeconds);
    assert.equal(chunks[chunks.length - 1]!.endSeconds, segments[segments.length - 1]!.endSeconds);
  });

  it('sections a 60-minute ramble into several parts', () => {
    const sections = sectionSegments(makeSegments(400, 200));
    assert.ok(sections.length > 1, 'a long recording should be sectioned');
    // Sections are contiguous and ordered.
    for (let i = 1; i < sections.length; i += 1) {
      assert.ok(sections[i]!.startSeconds >= sections[i - 1]!.startSeconds);
    }
  });

  it('prefers to break sections at a long pause', () => {
    const segments = makeSegments(20, 400);
    // Insert a clear pause after segment 9.
    for (let i = 10; i < segments.length; i += 1) segments[i]!.startSeconds += 8;
    const sections = sectionSegments(segments);
    assert.ok(sections.length > 1);
  });
});

describe('punctuation segmentation', () => {
  it('splits on sentence boundaries and spans the full duration', () => {
    const segments = segmentByPunctuation('One thing. Two thing. Three thing.', 30);
    assert.equal(segments.length, 3);
    assert.equal(segments[0]!.startSeconds, 0);
    assert.ok(Math.abs(segments[2]!.endSeconds - 30) < 0.001);
  });

  it('handles text with no terminal punctuation', () => {
    const segments = segmentByPunctuation('just one run on thought', 10);
    assert.equal(segments.length, 1);
  });
});
