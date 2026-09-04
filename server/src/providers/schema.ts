import { z } from 'zod';

/**
 * The structured extraction contract.
 *
 * Model output is validated against this before anything is written. A
 * malformed response fails the understanding stage and is retried rather than
 * being partially persisted.
 */

export const ITEM_KINDS = [
  'summary', 'note', 'idea', 'task', 'reminder', 'decision',
  'question', 'journal', 'commitment', 'follow_up', 'reference',
] as const;

export const ENTITY_KINDS = [
  'person', 'organization', 'project', 'place', 'product', 'topic',
] as const;

export const ACTION_TYPES = [
  'reminder.create', 'task.create', 'note.create',
  'calendar.create_event', 'calendar.update_event',
  'email.draft', 'email.send',
  'webhook.trigger', 'integration.invoke', 'mcp.invoke',
] as const;

/**
 * How consequential a statement is. Drives the confirmation policy far more
 * than raw model confidence does: a confidently-detected email send still
 * needs a human, a hesitantly-detected note does not.
 */
export const INTENT_CLASSES = [
  'information',            // "I think we should lower the price."
  'intention',              // "I need to lower the price."
  'explicit_action',        // "Change the price in the document."
  'external_communication', // "Email Sarah and tell her."
] as const;

export const extractedItemSchema = z.object({
  kind: z.enum(ITEM_KINDS),
  title: z.string().min(1).max(200),
  body: z.string().max(4000).nullish(),
  confidence: z.number().min(0).max(1),
  /** Verbatim span from the transcript that justifies this item. */
  source_quote: z.string().max(1000).nullish(),
  attributes: z
    .object({
      due_at: z.string().nullish(),
      priority: z.enum(['low', 'normal', 'high']).nullish(),
      url: z.string().nullish(),
      people: z.array(z.string()).nullish(),
    })
    .passthrough()
    .default({}),
});

export const extractedEntitySchema = z.object({
  kind: z.enum(ENTITY_KINDS),
  name: z.string().min(1).max(200),
  /** Other surface forms used in this ramble, e.g. "Sarah" for "Sarah Chen". */
  aliases: z.array(z.string()).default([]),
  context: z.string().max(500).nullish(),
  confidence: z.number().min(0).max(1),
});

export const extractedRelationshipSchema = z.object({
  from: z.string(),
  to: z.string(),
  kind: z.string().max(60),
  confidence: z.number().min(0).max(1),
});

export const extractedActionSchema = z.object({
  type: z.enum(ACTION_TYPES),
  intent_class: z.enum(INTENT_CLASSES),
  confidence: z.number().min(0).max(1),
  /** Free-form; each adapter validates its own required parameters. */
  parameters: z.record(z.unknown()).default({}),
  source_quote: z.string().max(1000).nullish(),
});

export const understandingResultSchema = z.object({
  title: z.string().min(1).max(120),
  summary: z.string().min(1).max(2000),
  clean_transcript: z.string().nullish(),
  language: z.string().max(20).nullish(),
  items: z.array(extractedItemSchema).max(100).default([]),
  entities: z.array(extractedEntitySchema).max(60).default([]),
  relationships: z.array(extractedRelationshipSchema).max(60).default([]),
  actions: z.array(extractedActionSchema).max(40).default([]),
});

export type ExtractedItem = z.infer<typeof extractedItemSchema>;
export type ExtractedEntity = z.infer<typeof extractedEntitySchema>;
export type ExtractedAction = z.infer<typeof extractedActionSchema>;
export type UnderstandingResult = z.infer<typeof understandingResultSchema>;
export type IntentClass = (typeof INTENT_CLASSES)[number];
export type ActionType = (typeof ACTION_TYPES)[number];

/** The JSON Schema handed to the model as a tool definition. */
export const understandingJsonSchema = {
  type: 'object',
  required: ['title', 'summary', 'items', 'entities', 'actions'],
  properties: {
    title: { type: 'string', description: 'Short specific title, 2-6 words. No trailing period.' },
    summary: { type: 'string', description: 'One or two sentences covering everything discussed.' },
    clean_transcript: {
      type: 'string',
      description: 'The transcript with filler words and false starts removed. Never paraphrased.',
    },
    language: { type: 'string' },
    items: {
      type: 'array',
      items: {
        type: 'object',
        required: ['kind', 'title', 'confidence'],
        properties: {
          kind: { type: 'string', enum: [...ITEM_KINDS] },
          title: { type: 'string' },
          body: { type: 'string' },
          confidence: { type: 'number' },
          source_quote: { type: 'string', description: 'Verbatim span from the transcript.' },
          attributes: {
            type: 'object',
            properties: {
              due_at: { type: 'string', description: 'ISO 8601 datetime if a time was stated.' },
              priority: { type: 'string', enum: ['low', 'normal', 'high'] },
              url: { type: 'string' },
              people: { type: 'array', items: { type: 'string' } },
            },
          },
        },
      },
    },
    entities: {
      type: 'array',
      items: {
        type: 'object',
        required: ['kind', 'name', 'confidence'],
        properties: {
          kind: { type: 'string', enum: [...ENTITY_KINDS] },
          name: { type: 'string', description: 'Fullest form used, e.g. "Sarah Chen" not "Sarah".' },
          aliases: { type: 'array', items: { type: 'string' } },
          context: { type: 'string' },
          confidence: { type: 'number' },
        },
      },
    },
    relationships: {
      type: 'array',
      items: {
        type: 'object',
        required: ['from', 'to', 'kind', 'confidence'],
        properties: {
          from: { type: 'string' },
          to: { type: 'string' },
          kind: { type: 'string', description: 'e.g. works_at, involves, part_of' },
          confidence: { type: 'number' },
        },
      },
    },
    actions: {
      type: 'array',
      items: {
        type: 'object',
        required: ['type', 'intent_class', 'confidence'],
        properties: {
          type: { type: 'string', enum: [...ACTION_TYPES] },
          intent_class: { type: 'string', enum: [...INTENT_CLASSES] },
          confidence: { type: 'number' },
          parameters: { type: 'object' },
          source_quote: { type: 'string' },
        },
      },
    },
  },
} as const;
