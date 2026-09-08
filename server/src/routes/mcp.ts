import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { pool } from '../db/pool.ts';
import { HttpError, requireUser } from '../lib/auth.ts';
import { log } from '../lib/logger.ts';
import { track } from '../lib/analytics.ts';
import { hybridSearch, inferKinds } from '../pipeline/search.ts';
import { createAnswerProvider } from '../providers/answer.ts';
import { enqueue } from '../pipeline/queue.ts';
import { withTransaction } from '../db/pool.ts';
import { randomUUID } from 'node:crypto';

/**
 * Ramble over the Model Context Protocol, so an agent can use someone's own
 * memory as context.
 *
 * ONE RULE SHAPES ALL OF THIS: these tools read and they create. They cannot
 * approve, execute, edit, or delete anything.
 *
 * Ramble's whole safety model is that a human says yes before software acts on
 * their behalf, and that anything reaching another person is confirmed every
 * single time. An agent that could call an "approve action" tool would route
 * straight around that — the confirmation would be given by the same system
 * that proposed it, which is not a confirmation at all. So the destructive and
 * approving verbs are simply not exposed. Actions surfaced here are read-only
 * facts about what is waiting; approving them still requires a person in the
 * app.
 *
 * Transport is plain JSON-RPC 2.0 over POST, which is the Streamable HTTP
 * transport minus the streaming. Hand-rolled rather than pulled from an SDK:
 * the surface is five tools and an initialize handshake, and the auth and
 * safety decisions above are ones worth being able to read in one file.
 */

const PROTOCOL_VERSION = '2025-06-18';

const answerProvider = createAnswerProvider();

interface Tool {
  name: string;
  title: string;
  description: string;
  inputSchema: Record<string, unknown>;
  /** Advertised so a client can show the person what it is about to do. */
  readOnly: boolean;
  run(userId: string, args: Record<string, unknown>): Promise<unknown>;
}

const TOOLS: Tool[] = [
  {
    name: 'search_rambles',
    title: 'Search recordings',
    description:
      "Search everything the person has said, across all their recordings. Returns matching passages with the recording each came from. Use this before answering anything about what they have thought, decided, or committed to.",
    readOnly: true,
    inputSchema: {
      type: 'object',
      required: ['query'],
      properties: {
        query: { type: 'string', description: 'What to look for, in natural language.' },
        limit: { type: 'integer', minimum: 1, maximum: 25, default: 10 },
      },
    },
    async run(userId, args) {
      const { query, limit } = z
        .object({ query: z.string().min(1).max(500), limit: z.number().int().min(1).max(25).default(10) })
        .parse(args);
      const hits = await hybridSearch(userId, query, { limit });
      return {
        results: hits.map((hit) => ({
          ramble_id: hit.rambleId,
          ramble_title: hit.rambleTitle,
          recorded_at: hit.recordedAt,
          kind: hit.sourceKind,
          content: hit.content,
        })),
      };
    },
  },
  {
    name: 'ask_ramble',
    title: 'Ask about their recordings',
    description:
      "Ask a question and get an answer synthesized only from the person's own recordings, with citations. Returns no answer rather than a guess when their recordings do not contain one.",
    readOnly: true,
    inputSchema: {
      type: 'object',
      required: ['question'],
      properties: { question: { type: 'string', description: 'The question, in natural language.' } },
    },
    async run(userId, args) {
      const { question } = z.object({ question: z.string().min(1).max(1000) }).parse(args);
      const hits = await hybridSearch(userId, question, { limit: 12, kinds: inferKinds(question) });
      const result = await answerProvider.answer(
        question,
        hits.map((hit) => ({
          rambleId: hit.rambleId,
          rambleTitle: hit.rambleTitle ?? 'Untitled',
          recordedAt: hit.recordedAt,
          sourceKind: hit.sourceKind,
          content: hit.content,
        })),
      );
      return { answer: result.answer, citations: result.citations, simulated: result.mocked };
    },
  },
  {
    name: 'list_open_items',
    title: 'List what is still open',
    description:
      'Tasks, reminders, commitments, follow-ups, and unanswered questions the person still has open, across every recording. Read-only.',
    readOnly: true,
    inputSchema: {
      type: 'object',
      properties: { limit: { type: 'integer', minimum: 1, maximum: 100, default: 50 } },
    },
    async run(userId, args) {
      const { limit } = z.object({ limit: z.number().int().min(1).max(100).default(50) }).parse(args);
      const { rows } = await pool.query(
        `SELECT i.kind, i.title, i.body, i.attributes->>'due_at' AS due_at,
                i.ramble_id, r.title AS ramble_title
           FROM extracted_items i
           JOIN rambles r ON r.id = i.ramble_id
          WHERE i.user_id = $1 AND i.status = 'open'
            AND i.kind IN ('task','reminder','commitment','follow_up','question')
          ORDER BY (i.attributes->>'due_at') NULLS LAST, i.created_at DESC
          LIMIT $2`,
        [userId, limit],
      );
      return { open_items: rows };
    },
  },
  {
    name: 'list_pending_actions',
    title: 'List actions awaiting the person',
    description:
      'Actions Ramble proposed that are waiting for the person to approve. READ-ONLY BY DESIGN: there is no tool to approve one. Approval requires a human in the app, and that is deliberate.',
    readOnly: true,
    inputSchema: { type: 'object', properties: {} },
    async run(userId) {
      const { rows } = await pool.query(
        `SELECT a.type, a.parameters, a.intent_class, a.risk, a.created_at,
                a.ramble_id, r.title AS ramble_title, i.source_quote
           FROM actions a
           JOIN rambles r ON r.id = a.ramble_id
           LEFT JOIN extracted_items i ON i.id = a.extracted_item_id
          WHERE a.user_id = $1 AND a.state = 'awaiting_confirmation'
          ORDER BY a.created_at DESC LIMIT 50`,
        [userId],
      );
      return {
        pending_actions: rows,
        note: 'These can only be approved by the person, in the app.',
      };
    },
  },
  {
    name: 'create_ramble',
    title: 'Add a thought',
    description:
      "Record a thought on the person's behalf as text. It goes through the same understanding as anything they say themselves: it will be read, structured, and may produce actions — which will then wait for the person to approve them. Use this to capture something, never to act on it.",
    readOnly: false,
    inputSchema: {
      type: 'object',
      required: ['text'],
      properties: {
        text: { type: 'string', description: 'What to record, in the person\'s own words where possible.' },
      },
    },
    async run(userId, args) {
      const { text } = z.object({ text: z.string().min(1).max(50_000) }).parse(args);
      const body = text.trim();
      if (!body) throw new HttpError(400, 'There is nothing in that.');

      const rambleId = await withTransaction(async (client) => {
        const { rows } = await client.query<{ id: string }>(
          `INSERT INTO rambles (user_id, client_id, recorded_at, duration_seconds,
                                source_device, processing_state)
           VALUES ($1,$2,now(),0,'import','transcribed') RETURNING id`,
          [userId, `mcp-${randomUUID()}`],
        );
        const id = rows[0]!.id;
        const { rows: transcripts } = await client.query<{ id: string }>(
          `INSERT INTO transcripts (ramble_id, user_id, provider, model, raw_text, origin)
           VALUES ($1,$2,'mcp','none',$3,'device') RETURNING id`,
          [id, userId, body],
        );
        await client.query(
          `INSERT INTO transcript_segments
             (transcript_id, ramble_id, user_id, idx, start_seconds, end_seconds, text)
           VALUES ($1,$2,$3,0,0,0,$4)`,
          [transcripts[0]!.id, id, userId, body],
        );
        return id;
      });

      enqueue(rambleId);
      await track(userId, 'ramble_created', { source_device: 'import', mcp: true });
      return {
        ramble_id: rambleId,
        note: 'Recorded. Anything it proposes will wait for the person to approve it.',
      };
    },
  },
];

const requestSchema = z.object({
  jsonrpc: z.literal('2.0'),
  id: z.union([z.string(), z.number()]).nullish(),
  method: z.string(),
  params: z.record(z.unknown()).optional(),
});

export async function mcpRoutes(app: FastifyInstance): Promise<void> {
  /**
   * A discovery document, so a person can point a client at the base URL and
   * be told what this is and how to authenticate.
   */
  app.get('/mcp', async () => ({
    name: 'ramble',
    version: '0.1.0',
    protocol: PROTOCOL_VERSION,
    transport: 'http',
    authentication: 'Bearer token from /v1/auth/login',
    tools: TOOLS.map((t) => ({ name: t.name, title: t.title, read_only: t.readOnly })),
    note: 'Read and create only. Approving or executing an action requires the person, in the app.',
  }));

  app.post('/mcp', async (request: FastifyRequest, reply) => {
    const parsed = requestSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({
        jsonrpc: '2.0',
        id: null,
        error: { code: -32600, message: 'Not a valid JSON-RPC request.' },
      });
    }
    const { id, method, params } = parsed.data;

    // A notification has no id and expects no reply.
    const isNotification = id === undefined || id === null;
    const ok = (result: unknown) =>
      isNotification ? reply.code(204).send() : reply.send({ jsonrpc: '2.0', id, result });
    const fail = (code: number, message: string) =>
      isNotification
        ? reply.code(204).send()
        : reply.send({ jsonrpc: '2.0', id, error: { code, message } });

    try {
      switch (method) {
        case 'initialize':
          return ok({
            protocolVersion: PROTOCOL_VERSION,
            capabilities: { tools: { listChanged: false } },
            serverInfo: { name: 'ramble', version: '0.1.0' },
            instructions:
              "This is one person's private thinking, captured by voice. Search it before answering " +
              'anything about what they have decided, promised, or been meaning to do. You can add a ' +
              'thought on their behalf, but you cannot approve anything: actions wait for them.',
          });

        case 'notifications/initialized':
          return reply.code(204).send();

        case 'ping':
          return ok({});

        case 'tools/list':
          return ok({
            tools: TOOLS.map((tool) => ({
              name: tool.name,
              title: tool.title,
              description: tool.description,
              inputSchema: tool.inputSchema,
              annotations: { readOnlyHint: tool.readOnly, destructiveHint: false },
            })),
          });

        case 'tools/call': {
          // Auth is checked here rather than at the route, so `initialize` and
          // `tools/list` work for a client that is still setting itself up.
          const user = await requireUser(request);
          const call = z
            .object({ name: z.string(), arguments: z.record(z.unknown()).default({}) })
            .parse(params ?? {});

          const tool = TOOLS.find((t) => t.name === call.name);
          if (!tool) return fail(-32602, `No tool named "${call.name}".`);

          log.info('mcp.tool_called', { tool: tool.name, user_id: user.id });
          const result = await tool.run(user.id, call.arguments);

          return ok({
            content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
            structuredContent: result,
            isError: false,
          });
        }

        default:
          return fail(-32601, `Unsupported method "${method}".`);
      }
    } catch (error) {
      if (error instanceof HttpError) {
        return reply.code(error.statusCode).send({
          jsonrpc: '2.0',
          id: id ?? null,
          error: { code: error.statusCode === 401 ? -32001 : -32603, message: error.message },
        });
      }
      log.error('mcp.failed', {
        method,
        error: error instanceof Error ? error.message : String(error),
      });
      return fail(-32603, 'Something went wrong handling that.');
    }
  });
}
