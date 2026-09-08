import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { routeAction, statedDestination } from '../src/actions/routing.ts';
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

describe('routing an action to the destination the person named', () => {
  it('sends "add driving hour to my calendar" to the calendar, not to reminders', () => {
    // The reported bug, verbatim. The model reached for reminder.create
    // because it was given ten action types and no guidance between them.
    const { action: routed, movedFrom } = routeAction(action());
    assert.equal(movedFrom, 'reminder.create');
    assert.equal(routed.type, 'calendar.create_event');
  });

  it('moves the time onto the field a calendar event actually reads', () => {
    // A re-route that left the time in due_at would validate cleanly and then
    // land an event with no time on it — quieter than the original bug, and
    // worse.
    const { action: routed } = routeAction(
      action({ parameters: { title: 'Driving hour', due_at: '2026-09-08T16:00:00.000Z' } }),
    );
    assert.equal(routed.parameters.starts_at, '2026-09-08T16:00:00.000Z');
    assert.equal(routed.parameters.due_at, undefined);
  });

  it('leaves a genuine reminder alone', () => {
    const { action: routed, movedFrom } = routeAction(
      action({ source_quote: 'Remind me tomorrow to call the garage.' }),
    );
    assert.equal(movedFrom, undefined);
    assert.equal(routed.type, 'reminder.create');
  });

  it('defers to the model when both destinations are named', () => {
    // "Remind me to put the meeting on my calendar" is genuinely ambiguous.
    // Guessing between the two is the behaviour this module exists to prevent.
    const { movedFrom } = routeAction(
      action({ source_quote: 'Remind me to put the meeting on my calendar.' }),
    );
    assert.equal(movedFrom, undefined);
  });

  it('leaves an action alone when no destination was named', () => {
    const { movedFrom } = routeAction(
      action({ source_quote: 'I need to finish the pricing page by Thursday.' }),
    );
    assert.equal(movedFrom, undefined);
  });

  it('never re-routes something that reaches another person', () => {
    // "Email Sarah about the calendar" names a topic, not a destination.
    // Turning it into a calendar event would be far worse than the bug.
    const { action: routed, movedFrom } = routeAction(
      action({
        type: 'email.send',
        intent_class: 'external_communication',
        source_quote: 'Email Sarah about the calendar for next week.',
      }),
    );
    assert.equal(movedFrom, undefined);
    assert.equal(routed.type, 'email.send');
  });

  it('sends a calendar event to reminders when that is what was asked for', () => {
    const { action: routed } = routeAction(
      action({
        type: 'calendar.create_event',
        source_quote: 'Set a reminder to renew the insurance.',
        parameters: {
          title: 'Renew the insurance',
          starts_at: '2026-09-09T09:00:00.000Z',
          location: 'the broker',
        },
      }),
    );
    assert.equal(routed.type, 'reminder.create');
    assert.equal(routed.parameters.due_at, '2026-09-09T09:00:00.000Z');
    assert.equal(routed.parameters.starts_at, undefined);
    // A reminder has nowhere to put a location, so it is kept in the notes
    // rather than dropped by schema validation on the way through.
    assert.match(String(routed.parameters.notes), /the broker/);
  });

  it('falls back to the title only when there is no quote to read', () => {
    const { action: routed } = routeAction(
      action({ source_quote: undefined, parameters: { title: 'Put the dentist on my calendar' } }),
    );
    assert.equal(routed.type, 'calendar.create_event');
  });
});

describe('reading a stated destination', () => {
  it('hears the destinations people actually name', () => {
    assert.equal(statedDestination('put it on my calendar'), 'calendar');
    assert.equal(statedDestination('schedule it for Tuesday'), 'calendar');
    assert.equal(statedDestination('remind me at six'), 'reminder');
    assert.equal(statedDestination('add it to my to-do list'), 'task');
    assert.equal(statedDestination('make a note of that'), 'note');
  });

  it('does not hear a destination in a passing mention', () => {
    // The words appear, but nobody is being told where to put anything.
    assert.equal(statedDestination('my schedule is packed this week'), null);
    assert.equal(statedDestination('the event went really well'), null);
    assert.equal(statedDestination('I should book the flight'), null);
  });
});
