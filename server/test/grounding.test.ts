import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { groundActions, isGrounded } from '../src/actions/grounding.ts';
import type { ExtractedAction } from '../src/providers/schema.ts';

function action(overrides: Partial<ExtractedAction> = {}): ExtractedAction {
  return {
    type: 'reminder.create',
    intent_class: 'explicit_action',
    confidence: 0.9,
    parameters: { title: 'Driving hour' },
    source_quote: 'Add driving hour to my calendar.',
    ...overrides,
  } as ExtractedAction;
}

const TRANSCRIPT = 'Add driving hour to my calendar.';

describe('grounding actions in what was actually said', () => {
  it('drops an action assembled out of the prompt\'s own examples', () => {
    // Observed from the live model: asked to process "Add driving hour to my
    // calendar", it returned a reminder titled "Send Sarah the pricing sheet",
    // lifted from the instructions. It validates, and it would have landed in
    // the person's Reminders as something they never said.
    const fabricated = action({
      source_quote: undefined,
      parameters: {
        title: 'Send Sarah the pricing sheet',
        body: 'Please send me the pricing sheet by Friday.',
      },
    });
    assert.equal(isGrounded(fabricated, TRANSCRIPT), false);
  });

  it('keeps an action the person actually asked for', () => {
    assert.equal(isGrounded(action(), TRANSCRIPT), true);
  });

  it('keeps a quote that trimmed a filler word', () => {
    // Trimming "um" and "my" is accuracy, not invention. A strict substring
    // check would throw this away.
    const trimmed = action({ source_quote: 'add driving hour to calendar' });
    assert.equal(isGrounded(trimmed, 'Um, add driving hour to my calendar.'), true);
  });

  it('falls back to the title when the model omitted the quote', () => {
    const titled = action({
      source_quote: undefined,
      parameters: { title: 'Add driving hour to my calendar' },
    });
    assert.equal(isGrounded(titled, TRANSCRIPT), true);
  });

  it('keeps an action whose quote drifted but whose title is sound', () => {
    // Two independent claims about what was heard. One of them tracing back to
    // the transcript is enough; only inventing both is fabrication.
    const drifted = action({
      source_quote: 'the user would like this placed into their calendar app',
      parameters: { title: 'Add driving hour to my calendar' },
    });
    assert.equal(isGrounded(drifted, TRANSCRIPT), true);
  });

  it('keeps a quote that only differs by an inflection', () => {
    // Observed false positive: the model titled it "Finish the pricing page"
    // from "add finishing the pricing page...". Exact matching scored that at
    // 0.75 and threw away a real action.
    const inflected = action({
      source_quote: undefined,
      parameters: { title: 'Finish the pricing page' },
    });
    assert.equal(
      isGrounded(inflected, 'Add finishing the pricing page to my to-do list.'),
      true,
    );
  });

  it('does not treat two different words as one because they share a prefix', () => {
    const unrelated = action({
      source_quote: undefined,
      parameters: { title: 'Call Priya about the calendar' },
    });
    assert.equal(isGrounded(unrelated, 'Buy milk and bread on the way home.'), false);
  });

  it('gives the benefit of the doubt to a quote too short to judge', () => {
    // "Buy milk" is two words. Below that length an overlap score says more
    // about chance than about accuracy.
    const terse = action({ source_quote: 'Buy milk', parameters: { title: 'Buy milk' } });
    assert.equal(isGrounded(terse, 'Buy milk on the way home.'), true);
  });

  it('drops an action with no evidence at all', () => {
    const bare = action({ source_quote: undefined, parameters: {} as never });
    assert.equal(isGrounded(bare, TRANSCRIPT), false);
  });

  it('reports what it threw away so the drift is visible', () => {
    const { actions, dropped } = groundActions(
      [
        action(),
        action({
          source_quote: 'Email Sarah the revised pricing before Friday.',
          parameters: { title: 'Email Sarah the revised pricing' },
        }),
      ],
      TRANSCRIPT,
    );
    assert.equal(actions.length, 1);
    assert.equal(dropped.length, 1);
    assert.match(dropped[0]!.evidence, /Email Sarah/);
  });
});
