import type { ExtractedAction } from '../providers/schema.ts';

/**
 * Throws away actions that cannot be traced to something the person said.
 *
 * A small model under a long prompt sometimes emits an action built out of the
 * prompt's own examples: asked to process "Add driving hour to my calendar",
 * it has been observed returning a reminder titled "Send Sarah the pricing
 * sheet", lifted verbatim from the instructions. Nothing downstream catches
 * this — the action is well-formed, it validates, and it lands in the person's
 * Reminders as a thing they never said.
 *
 * Rule 3 of the prompt already requires a quote for everything extracted. This
 * enforces it for actions, which are the ones that actually do something. An
 * action that cannot be grounded in the transcript is dropped rather than
 * surfaced, because the guide is unambiguous: never invent a commitment.
 */

/** Lowercased words, punctuation removed, so quoting style cannot matter. */
function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .split(/\s+/)
    .filter(Boolean);
}

/**
 * How much of the quote actually appears in the transcript.
 *
 * Deliberately a token overlap rather than a substring match. A model that
 * trims a filler word — quoting "add driving hour to calendar" from "um, add
 * driving hour to my calendar" — is being accurate, not inventive, and a
 * strict containment check would throw that away.
 */
function overlap(quote: string, transcript: string[]): number {
  const words = tokenize(quote);
  if (words.length === 0) return 0;
  const found = words.filter((word) => appearsIn(word, transcript)).length;
  return found / words.length;
}

/**
 * Whether a word was said, allowing for the endings English puts on things.
 *
 * A model quoting "finish the pricing page" from "add finishing the pricing
 * page to my to-do list" is quoting correctly; only the inflection moved. An
 * exact-match check scored that at 0.75 and threw away a real action, so a
 * shared prefix counts as the same word. Four characters is long enough that
 * "call" and "calendar" stay distinct.
 */
const STEM_AT = 4;

function appearsIn(word: string, transcript: string[]): boolean {
  if (transcript.includes(word)) return true;
  if (word.length < STEM_AT) return false;
  return transcript.some(
    (spoken) => spoken.length >= STEM_AT && (spoken.startsWith(word) || word.startsWith(spoken)),
  );
}

/** Below this share of matching words, the action is about something else. */
const GROUNDED_AT = 0.8;

/** Too few words to judge; the benefit of the doubt goes to the person. */
const MINIMUM_WORDS = 3;

export function isGrounded(action: ExtractedAction, transcript: string): boolean {
  const vocabulary = tokenize(transcript);

  // Either the quote or the title grounding it is enough. They are two
  // independent claims about what was heard, and a model that paraphrases one
  // while getting the other right is still working from the transcript. Only
  // when neither traces back to it is the action invented — which is exactly
  // the observed failure, where the quote was missing and the title came from
  // the prompt.
  const title = typeof action.parameters?.title === 'string' ? action.parameters.title : '';
  const claims = [action.source_quote?.trim(), title.trim()].filter(
    (claim): claim is string => Boolean(claim),
  );
  if (claims.length === 0) return false;

  return claims.some((claim) => {
    // Too few words to judge: an overlap score on two words says more about
    // chance than about accuracy, so the benefit of the doubt goes to the person.
    if (tokenize(claim).length < MINIMUM_WORDS) return true;
    return overlap(claim, vocabulary) >= GROUNDED_AT;
  });
}

export interface Grounding {
  actions: ExtractedAction[];
  /** What was thrown away, for logging. */
  dropped: { type: string; evidence: string }[];
}

export function groundActions(actions: ExtractedAction[], transcript: string): Grounding {
  const kept: ExtractedAction[] = [];
  const dropped: { type: string; evidence: string }[] = [];

  for (const action of actions) {
    if (isGrounded(action, transcript)) {
      kept.push(action);
    } else {
      dropped.push({
        type: action.type,
        evidence: action.source_quote?.trim()
          || (typeof action.parameters?.title === 'string' ? action.parameters.title : '(none)'),
      });
    }
  }
  return { actions: kept, dropped };
}
