import { z } from 'zod';
import type { ActionType } from '../providers/schema.ts';

/**
 * Where an action runs.
 *
 *  server - executed by the backend (internal records, webhooks, OAuth
 *           integrations the server holds tokens for).
 *  client - executed on the device. Apple Calendar and Reminders live behind
 *           EventKit, which only exists on-device, so the app claims approved
 *           actions and reports results back. This also keeps the user's
 *           calendar out of the server entirely.
 */
export type ExecutionTarget = 'server' | 'client';

export interface ActionDefinition {
  type: ActionType;
  target: ExecutionTarget;
  /** Human phrasing for the confirmation card, e.g. "Add to Calendar". */
  label: string;
  parameters: z.ZodType;
  /** Whether the action needs a connected integration before it can run. */
  requiresIntegration?: string;
}

const isoDate = z
  .string()
  .refine((v) => !Number.isNaN(Date.parse(v)), { message: 'must be an ISO 8601 datetime' });

export const ACTION_DEFINITIONS: Record<ActionType, ActionDefinition> = {
  'note.create': {
    type: 'note.create',
    target: 'server',
    label: 'Save note',
    parameters: z.object({ title: z.string().min(1), body: z.string().optional() }),
  },
  'task.create': {
    type: 'task.create',
    target: 'server',
    label: 'Add task',
    parameters: z.object({
      title: z.string().min(1),
      due_at: isoDate.optional(),
      priority: z.enum(['low', 'normal', 'high']).optional(),
    }),
  },
  'reminder.create': {
    type: 'reminder.create',
    target: 'client',
    label: 'Add reminder',
    parameters: z.object({
      title: z.string().min(1),
      due_at: isoDate.optional(),
      notes: z.string().optional(),
    }),
  },
  'calendar.create_event': {
    type: 'calendar.create_event',
    target: 'client',
    label: 'Add to calendar',
    parameters: z.object({
      title: z.string().min(1),
      starts_at: isoDate.optional(),
      ends_at: isoDate.optional(),
      duration_minutes: z.number().int().positive().optional(),
      location: z.string().optional(),
      notes: z.string().optional(),
    }),
  },
  'calendar.update_event': {
    type: 'calendar.update_event',
    target: 'client',
    label: 'Change calendar event',
    parameters: z.object({
      event_id: z.string().optional(),
      title: z.string().optional(),
      starts_at: isoDate.optional(),
      ends_at: isoDate.optional(),
    }),
  },
  'email.draft': {
    type: 'email.draft',
    target: 'server',
    label: 'Draft email',
    parameters: z.object({
      to: z.array(z.string()).optional(),
      subject: z.string().optional(),
      body: z.string().optional(),
    }),
  },
  'email.send': {
    type: 'email.send',
    target: 'server',
    label: 'Send email',
    requiresIntegration: 'gmail',
    parameters: z.object({
      to: z.array(z.string()).min(1),
      subject: z.string().min(1),
      body: z.string().min(1),
    }),
  },
  'webhook.trigger': {
    type: 'webhook.trigger',
    target: 'server',
    label: 'Trigger webhook',
    parameters: z.object({ event: z.string().min(1), payload: z.record(z.unknown()).optional() }),
  },
  'integration.invoke': {
    type: 'integration.invoke',
    target: 'server',
    label: 'Run integration',
    parameters: z.object({ provider: z.string().min(1), operation: z.string().min(1), arguments: z.record(z.unknown()).optional() }),
  },
  'mcp.invoke': {
    type: 'mcp.invoke',
    target: 'server',
    label: 'Run tool',
    parameters: z.object({ server: z.string().min(1), tool: z.string().min(1), arguments: z.record(z.unknown()).optional() }),
  },
};

export function definitionFor(type: string): ActionDefinition | undefined {
  return ACTION_DEFINITIONS[type as ActionType];
}

/**
 * Validates parameters against the action's own schema. Returning a result
 * rather than throwing lets the pipeline record a malformed action as failed
 * instead of losing the whole ramble.
 */
export function validateParameters(
  type: string,
  parameters: unknown,
): { ok: true; value: Record<string, unknown> } | { ok: false; error: string } {
  const definition = definitionFor(type);
  if (!definition) return { ok: false, error: `Unknown action type "${type}".` };
  const parsed = definition.parameters.safeParse(parameters ?? {});
  if (!parsed.success) {
    return {
      ok: false,
      error: parsed.error.issues.map((i) => `${i.path.join('.') || 'parameters'}: ${i.message}`).join('; '),
    };
  }
  return { ok: true, value: parsed.data as Record<string, unknown> };
}
