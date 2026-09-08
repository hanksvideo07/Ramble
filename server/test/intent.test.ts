import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { floorIntentClass, soundsLikeAnIntention } from '../src/actions/intent.ts';
import { decideConfirmation } from '../src/actions/policy.ts';
import type { ExtractedAction } from '../src/providers/schema.ts';

function action(overrides: Partial<ExtractedAction> = {}): ExtractedAction {
  return {
    type: 'task.create',
    intent_class: 'explicit_action',
    confidence: 0.9,
    parameters: { title: 'Finish the pricing page' },
    source_quote: 'I need to finish the pricing page.',
    ...overrides,
  } as ExtractedAction;
}

describe('holding back an intention the person only voiced', () => {
  it('stops "I need to..." running unattended', () => {
    // Observed flapping on identical input: the model called this an
    // explicit_action about half the time, and a low-risk explicit_action at
    // high confidence runs with no confirmation at all.
    const before = decideConfirmation({
      type: 'task.create',
      intentClass: 'explicit_action',
      confidence: 0.9,
    });
    assert.equal(before.requiresConfirmation, false);

    const floored = floorIntentClass(action());
    assert.equal(floored.intent_class, 'intention');

    const after = decideConfirmation({
      type: 'task.create',
      intentClass: floored.intent_class,
      confidence: 0.9,
    });
    assert.equal(after.requiresConfirmation, true);
  });

  it('leaves a request alone even when it is phrased around a need', () => {
    // "Remind me" asked for something. Making that wait for a confirmation
    // would break the promise the product is built on.
    const asked = action({
      type: 'reminder.create',
      source_quote: 'Remind me tomorrow, I need to call the garage.',
    });
    assert.equal(floorIntentClass(asked).intent_class, 'explicit_action');
  });

  it('treats two named destinations as a request, not an ambiguity', () => {
    // Routing stands aside here because it cannot tell which one to pick. The
    // floor has an easier question: they clearly asked for something.
    const both = action({
      source_quote: 'Remind me that I need to put the meeting on my calendar.',
    });
    assert.equal(floorIntentClass(both).intent_class, 'explicit_action');
  });

  it('leaves a plain instruction alone', () => {
    const instruction = action({ source_quote: 'Add finishing the pricing page to my to-do list.' });
    assert.equal(floorIntentClass(instruction).intent_class, 'explicit_action');
  });

  it('never touches anything already more cautious', () => {
    for (const intent of ['information', 'intention', 'external_communication'] as const) {
      const cautious = action({ intent_class: intent });
      assert.equal(floorIntentClass(cautious).intent_class, intent);
    }
  });

  it('can only ever add a confirmation, never remove one', () => {
    // The whole safety argument for this guard: it downgrades or does nothing.
    const floored = floorIntentClass(action());
    assert.notEqual(floored.intent_class, 'explicit_action');
  });

  it('hears a voiced intention, and not a request phrased with "you"', () => {
    assert.equal(soundsLikeAnIntention('I need to call the garage'), true);
    assert.equal(soundsLikeAnIntention('I should probably rewrite that'), true);
    assert.equal(soundsLikeAnIntention("we're going to lower the price"), true);
    // A request, not a plan — "to" does not directly follow the verb.
    assert.equal(soundsLikeAnIntention('I need you to email Sarah'), false);
    assert.equal(soundsLikeAnIntention('Add the meeting to my calendar'), false);
  });
});
