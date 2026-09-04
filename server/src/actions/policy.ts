import type { ActionType, IntentClass } from '../providers/schema.ts';

export type Risk = 'low' | 'medium' | 'high';

/**
 * Inherent risk of an action type, independent of how it was phrased.
 *
 * Low risk means reversible and private to the user: worst case they delete a
 * note. High risk means it leaves the user's own data — another person sees it,
 * or something existing is overwritten.
 */
const ACTION_RISK: Record<ActionType, Risk> = {
  'note.create': 'low',
  'task.create': 'low',
  'reminder.create': 'low',
  'calendar.create_event': 'medium',
  'calendar.update_event': 'high',
  'email.draft': 'medium',
  'email.send': 'high',
  'webhook.trigger': 'medium',
  'integration.invoke': 'high',
  'mcp.invoke': 'high',
};

/** Below this, even a low-risk action is worth a glance before it happens. */
const AUTO_EXECUTE_CONFIDENCE = 0.75;

export interface PolicyInput {
  type: ActionType;
  intentClass: IntentClass;
  confidence: number;
  /** Per-user overrides from users.settings, e.g. auto-confirm calendar events. */
  autoApprove?: Partial<Record<ActionType, boolean>>;
}

export interface PolicyDecision {
  risk: Risk;
  requiresConfirmation: boolean;
  reason: string;
}

/**
 * Decides whether an action may run unattended.
 *
 * The ordering matters: intent class is checked before confidence, because a
 * hallucinated intent that the model happens to feel sure about is exactly the
 * failure this guards against. A model cannot talk its way into sending an
 * email by being confident.
 */
export function decideConfirmation(input: PolicyInput): PolicyDecision {
  const risk = ACTION_RISK[input.type] ?? 'high';

  // Nothing a person merely observed or intended becomes an action on its own.
  // "I need to email Sarah" is a task for them, not a message from us.
  if (input.intentClass === 'information') {
    return { risk, requiresConfirmation: true, reason: 'Stated as an observation, not a request.' };
  }
  if (input.intentClass === 'intention') {
    return { risk, requiresConfirmation: true, reason: 'Stated as an intention, not an instruction.' };
  }

  // Anything reaching another person is confirmed every time, regardless of
  // confidence or user settings. This is deliberately not overridable.
  if (input.intentClass === 'external_communication') {
    return {
      risk: 'high',
      requiresConfirmation: true,
      reason: 'Reaches someone outside your own data.',
    };
  }

  if (risk === 'high') {
    return { risk, requiresConfirmation: true, reason: 'Overwrites or sends something.' };
  }

  if (input.confidence < AUTO_EXECUTE_CONFIDENCE) {
    return {
      risk,
      requiresConfirmation: true,
      reason: `Understood with ${Math.round(input.confidence * 100)}% confidence.`,
    };
  }

  // Medium-risk actions run unattended only if the user opted in for that type.
  if (risk === 'medium') {
    const approved = input.autoApprove?.[input.type] === true;
    return approved
      ? { risk, requiresConfirmation: false, reason: 'Auto-approved in your settings.' }
      : { risk, requiresConfirmation: true, reason: 'Creates something on your calendar.' };
  }

  return { risk, requiresConfirmation: false, reason: 'Low risk and clearly requested.' };
}

export function actionRisk(type: ActionType): Risk {
  return ACTION_RISK[type] ?? 'high';
}
