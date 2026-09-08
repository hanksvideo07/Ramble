import type { ExtractedAction } from '../providers/schema.ts';

/**
 * Sends an action where the person said to send it.
 *
 * A model asked to pick from ten action types with no guidance will reach for
 * a familiar one, and "add driving hour to my calendar" lands in Reminders.
 * The prompt now teaches the distinction, but a prompt cannot guarantee it,
 * and the cost of getting this wrong is the thing appearing somewhere the
 * person will not look for it.
 *
 * So when someone names the destination out loud, that naming wins. This is
 * deliberately not a general-purpose classifier: it never invents an action,
 * never removes one, and never touches anything that leaves the device. It
 * only re-routes an action that already exists, between the four places a
 * spoken thought can land, and only when the words are unambiguous.
 */

/** The four places a spoken thought can land. */
export type Destination = 'calendar' | 'reminder' | 'task' | 'note';

/**
 * Only these types are re-routable. Email, webhooks, and tool invocations are
 * never touched: "email Sarah about the calendar" names a topic, not a
 * destination, and quietly turning that into a calendar event would be far
 * worse than the bug this fixes.
 */
const ROUTABLE: Record<string, Destination> = {
  'calendar.create_event': 'calendar',
  'reminder.create': 'reminder',
  'task.create': 'task',
  'note.create': 'note',
};

const TYPE_FOR: Record<Destination, string> = {
  calendar: 'calendar.create_event',
  reminder: 'reminder.create',
  task: 'task.create',
  note: 'note.create',
};

/**
 * Phrases that name a destination rather than merely describing one.
 *
 * Kept tight on purpose. "Event" alone is not here because "the event went
 * well" names nothing, and "book" is not here because "book the flight" is a
 * task. A marker earns its place only if hearing it means the person was
 * telling us where to put something.
 */
const MARKERS: Record<Destination, RegExp[]> = {
  calendar: [
    /\bcalendars?\b/i,
    // "schedule it for Tuesday", "schedule a call" — the verb with an object.
    // Excludes "my schedule is packed", which names nothing.
    /\bschedule\s+(?:it|this|that|a|an|the|us|me)\b/i,
    /\bput\s+(?:it|this|that)\s+(?:in|on)\s+my\s+cal\b/i,
  ],
  reminder: [
    /\bremind\s+me\b/i,
    /\breminders?\b/i,
  ],
  task: [
    /\bto-?do\s+list\b/i,
    /\btask\s+list\b/i,
    /\bmy\s+tasks?\b/i,
  ],
  note: [
    /\b(?:take|make|leave)\s+a\s+note\b/i,
    /\b(?:note|jot|write)\s+(?:it|this|that)\s+down\b/i,
  ],
};

/**
 * The destination the person named, if they named exactly one.
 *
 * Two destinations in one breath — "remind me to put the meeting on my
 * calendar" — is a genuine ambiguity, and guessing between them is exactly
 * the behaviour this module exists to prevent. In that case the model's own
 * reading stands.
 */
export function statedDestination(text: string): Destination | null {
  const named = namedDestinations(text);
  return named.length === 1 ? named[0]! : null;
}

/**
 * Every destination named in the text.
 *
 * Routing needs exactly one to act on, but "did they ask for anything at all"
 * is a different question, and two destinations is emphatically a yes to it.
 */
export function namedDestinations(text: string): Destination[] {
  if (!text) return [];
  return (Object.keys(MARKERS) as Destination[]).filter((destination) =>
    MARKERS[destination].some((pattern) => pattern.test(text)),
  );
}

/**
 * Moves the time onto the field the new destination actually reads.
 *
 * A calendar event's time lives in `starts_at` and a reminder's in `due_at`.
 * Re-routing without translating would produce an action that validates and
 * then lands with no time on it at all, which is a quieter and worse failure
 * than the one being fixed.
 */
function retarget(
  parameters: Record<string, unknown>,
  to: Destination,
): Record<string, unknown> {
  const next = { ...parameters };
  const when = next.starts_at ?? next.due_at;

  if (to === 'calendar') {
    if (when != null) next.starts_at = when;
    delete next.due_at;
    return next;
  }

  // Everything else is a point in time rather than a span, so the end and the
  // length have nowhere to go. A location would otherwise be dropped silently
  // by schema validation, so it is folded into the notes instead.
  if (to === 'reminder' || to === 'task') {
    if (when != null) next.due_at = when;
  } else {
    delete next.due_at;
  }
  if (typeof next.location === 'string' && next.location.trim().length > 0) {
    const existing = typeof next.notes === 'string' && next.notes.trim().length > 0
      ? `${next.notes} `
      : '';
    next.notes = `${existing}At ${next.location}.`;
  }
  delete next.starts_at;
  delete next.ends_at;
  delete next.duration_minutes;
  delete next.location;
  return next;
}

export interface Rerouted {
  action: ExtractedAction;
  /** Set when this action was moved, for logging. Absent means untouched. */
  movedFrom?: string;
}

/**
 * Re-routes one action to the destination its source quote names.
 *
 * Returns the action unchanged whenever the person did not name a destination,
 * named more than one, named the one already chosen, or asked for something
 * that is not a matter of where to file it.
 */
export function routeAction(action: ExtractedAction): Rerouted {
  const current = ROUTABLE[action.type];
  if (!current) return { action };

  // The quote is what the person actually said. The title is the model's own
  // paraphrase, so it is only consulted when there is no quote to read.
  const spoken = action.source_quote?.trim()
    || (typeof action.parameters?.title === 'string' ? action.parameters.title : '');

  const stated = statedDestination(spoken);
  if (!stated || stated === current) return { action };

  return {
    movedFrom: action.type,
    action: {
      ...action,
      type: TYPE_FOR[stated] as ExtractedAction['type'],
      parameters: retarget(action.parameters ?? {}, stated),
    },
  };
}
