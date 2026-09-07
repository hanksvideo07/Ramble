import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { decideConfirmation } from '../src/actions/policy.ts';
import { sanitizeTitle } from '../src/providers/understanding.ts';

describe('action confirmation policy', () => {
  it('never sends external communication unattended, however confident', () => {
    const decision = decideConfirmation({
      type: 'email.send',
      intentClass: 'external_communication',
      confidence: 0.99,
    });
    assert.equal(decision.requiresConfirmation, true);
    assert.equal(decision.risk, 'high');
  });

  it('refuses to act on a musing even when it names an action', () => {
    // "I think we should email Sarah" is a thought, not an instruction.
    const decision = decideConfirmation({
      type: 'email.send',
      intentClass: 'information',
      confidence: 0.95,
    });
    assert.equal(decision.requiresConfirmation, true);
  });

  it('treats an intention as something for the user to do, not for us', () => {
    const decision = decideConfirmation({
      type: 'reminder.create',
      intentClass: 'intention',
      confidence: 0.95,
    });
    assert.equal(decision.requiresConfirmation, true);
  });

  it('runs a clearly requested low-risk action without interrupting', () => {
    const decision = decideConfirmation({
      type: 'reminder.create',
      intentClass: 'explicit_action',
      confidence: 0.9,
    });
    assert.equal(decision.requiresConfirmation, false);
  });

  it('asks first when it is not sure it understood', () => {
    const decision = decideConfirmation({
      type: 'reminder.create',
      intentClass: 'explicit_action',
      confidence: 0.4,
    });
    assert.equal(decision.requiresConfirmation, true);
    assert.match(decision.reason, /40% confidence/);
  });

  it('gates calendar events until the user opts in to that type', () => {
    const gated = decideConfirmation({
      type: 'calendar.create_event',
      intentClass: 'explicit_action',
      confidence: 0.95,
    });
    assert.equal(gated.requiresConfirmation, true);

    const optedIn = decideConfirmation({
      type: 'calendar.create_event',
      intentClass: 'explicit_action',
      confidence: 0.95,
      autoApprove: { 'calendar.create_event': true },
    });
    assert.equal(optedIn.requiresConfirmation, false);
  });

  it('does not let a user setting auto-approve an outbound email', () => {
    const decision = decideConfirmation({
      type: 'email.send',
      intentClass: 'external_communication',
      confidence: 0.99,
      autoApprove: { 'email.send': true },
    });
    assert.equal(decision.requiresConfirmation, true);
  });

  it('always confirms before overwriting an existing calendar event', () => {
    const decision = decideConfirmation({
      type: 'calendar.update_event',
      intentClass: 'explicit_action',
      confidence: 1,
    });
    assert.equal(decision.requiresConfirmation, true);
  });
});

describe('title sanitizing', () => {
  const base = {
    summary: 'Discussed pricing with Sarah at Nationwide.',
    items: [{ kind: 'task' as const, title: 'Send the pricing sheet', body: null, confidence: 0.8, source_quote: null, attributes: {} }],
    entities: [], relationships: [], actions: [], clean_transcript: null, language: 'en',
  };

  it('keeps a real title', () => {
    assert.equal(sanitizeTitle({ ...base, title: 'Nationwide pricing follow-up' }), 'Nationwide pricing follow-up');
  });

  it('replaces a title that describes the extraction instead of the recording', () => {
    // The model titled the recording after its own job, which is useless in a
    // timeline of fifty recordings.
    assert.equal(sanitizeTitle({ ...base, title: 'Extract items' }), 'Send the pricing sheet');
    assert.equal(sanitizeTitle({ ...base, title: 'Record Understanding' }), 'Send the pricing sheet');
  });

  it('falls back to the summary when there is no usable item', () => {
    assert.equal(
      sanitizeTitle({ ...base, items: [], title: 'Summarize the transcript' }),
      'Discussed pricing with Sarah at Nationwide',
    );
  });
});
