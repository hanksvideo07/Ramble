import type { ExtractedAction } from '../providers/schema.ts';
import { namedDestinations } from './routing.ts';

/**
 * Stops a voiced intention being read as an instruction.
 *
 * Rule 4 of the prompt is explicit that "I need to lower the price" is an
 * intention, and the confirmation policy leans on that: an intention always
 * waits for a yes, while an explicit_action of low risk runs unattended. So a
 * misread here is the difference between Ramble filing something for you and
 * Ramble filing something you were only thinking about.
 *
 * The model gets this right most of the time and wrong some of the time, on
 * identical input. Since the correction only ever adds a confirmation, never
 * removes one, it cannot make the system less safe than the model's own answer.
 */

/**
 * First-person phrasings that describe a plan rather than request one.
 *
 * "I need to" is an intention; "I need you to" is a request, and does not match
 * because the pattern requires "to" directly after the verb.
 */
const VOICED_INTENTION: RegExp[] = [
  /\b(?:i|we)\s+(?:really\s+|still\s+)?need\s+to\b/i,
  /\b(?:i|we)\s+(?:have|ought)\s+to\b/i,
  /\b(?:i|we)\s+(?:should|must)\b/i,
  /\b(?:i|we)\s+(?:want|would\s+like)\s+to\b/i,
  /\b(?:i'?m|we'?re)\s+going\s+to\b/i,
];

export function soundsLikeAnIntention(text: string): boolean {
  return VOICED_INTENTION.some((pattern) => pattern.test(text));
}

/**
 * Downgrades an action the person only voiced, so it waits for a yes.
 *
 * Naming a destination out loud — "remind me", "on my calendar", "on my to-do
 * list" — is a request whatever else the sentence contains. "Remind me, I need
 * to call the garage" asked for a reminder, and making that wait for a
 * confirmation would break the promise the product is built on.
 */
export function floorIntentClass(action: ExtractedAction): ExtractedAction {
  if (action.intent_class !== 'explicit_action') return action;

  const title = typeof action.parameters?.title === 'string' ? action.parameters.title : '';
  const spoken = action.source_quote?.trim() || title;
  if (!spoken) return action;

  if (!soundsLikeAnIntention(spoken)) return action;
  // Any destination named at all is a request, two included: "remind me to put
  // it on my calendar" asked for something, however it was phrased around it.
  if (namedDestinations(spoken).length > 0) return action;

  return { ...action, intent_class: 'intention' };
}
