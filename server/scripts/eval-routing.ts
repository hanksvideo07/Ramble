import 'dotenv/config';
import { createUnderstandingProvider } from '../src/providers/understanding.ts';
import { routeAction } from '../src/actions/routing.ts';

/**
 * Checks that a spoken thought lands where the person said to put it.
 *
 *   npm run eval:routing
 *
 * "Add driving hour to my calendar" once became an Apple Reminder, because the
 * model was handed ten action types and no guidance between them. This asks
 * the live model the same questions and reports which of the two fixes carried
 * each one: the prompt on its own, or the deterministic re-route behind it.
 */
/**
 * `expect` is about WHERE an action lands, never whether one is emitted —
 * rule 5 owns that, and eval-models.ts tests it. Where a phrasing is a stated
 * plan rather than a request, `requireAction: false` says that emitting
 * nothing is a fine answer, but emitting the wrong destination is not.
 */
const CASES: {
  text: string;
  expect: string | null;
  requireAction?: boolean;
  mustNotBeExplicit?: boolean;
}[] = [
  { text: 'Add driving hour to my calendar.',                         expect: 'calendar.create_event' },
  { text: 'Add driving hour to calendar.',                            expect: 'calendar.create_event' },
  { text: 'Put driving hour on the calendar for Tuesday at four.',    expect: 'calendar.create_event' },
  { text: 'Lunch with Ben on Friday at noon.',    expect: 'calendar.create_event', requireAction: false },
  { text: 'Schedule the standup for Wednesday morning.',              expect: 'calendar.create_event' },
  { text: 'Remind me tomorrow to call the garage about the brakes.',  expect: 'reminder.create' },
  { text: 'Set a reminder to renew the insurance next month.',        expect: 'reminder.create' },
  { text: 'Add finishing the pricing page to my to-do list.',         expect: 'task.create' },
  // "I need to" is an intention, not an instruction. Either no action or a
  // task awaiting a yes is fine; what must never happen is it being read as a
  // direct order. Guards rule 5 against the new rule 5b loosening it.
  { text: 'I need to finish the pricing page.',   expect: null, mustNotBeExplicit: true },
];

const provider = createUnderstandingProvider();
console.log(`provider: ${provider.name} (${provider.model})\n`);

let passed = 0;
let neededRerouting = 0;

for (const testCase of CASES) {
  try {
    const result = await provider.understand({
      transcript: testCase.text,
      recordedAt: new Date('2026-09-07T18:00:00Z'),
      timezone: 'America/New_York',
      knownEntities: [],
      profile: 'other',
    });

    const types = result.actions.map((a) => a.type);
    const upgraded = result.actions.some((a) => a.intent_class === 'explicit_action');
    const ok = testCase.mustNotBeExplicit
      ? !upgraded
      : types.length === 0
        ? testCase.expect === null || testCase.requireAction === false
        : testCase.expect !== null && types.includes(testCase.expect);
    if (ok) passed += 1;

    // The provider already applied the re-route, so ask what it did: an action
    // that would move again from its pre-route type tells us the prompt alone
    // was not enough for this phrasing.
    const rerouted = result.actions.some((a) => routeAction(a).movedFrom);
    if (rerouted) neededRerouting += 1;

    console.log(
      `${ok ? 'PASS' : 'FAIL'}  ${testCase.text}\n` +
        `      want ${testCase.mustNotBeExplicit ? 'not an instruction' : testCase.expect ?? 'no actions'}` +
          `   got [${types.join(', ') || 'no actions'}]${upgraded ? ' as explicit_action' : ''}`,
    );
  } catch (error) {
    console.log(`ERROR ${testCase.text}\n      ${(error as Error).message}`);
  }
}

console.log(`\n${passed}/${CASES.length} landed in the right place.`);
if (passed < CASES.length) process.exitCode = 1;
