import { config } from '../lib/config.ts';
import { log } from '../lib/logger.ts';

/**
 * Minimal OpenRouter client.
 *
 * OpenRouter speaks the OpenAI chat-completions dialect, so no vendor SDK is
 * needed — which also means swapping the model is a config change rather than
 * a code change.
 */

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  maxTokens?: number;
  temperature?: number;
  /** Ask for JSON matching this schema. Not every model honors it, so callers still validate. */
  jsonSchema?: { name: string; schema: unknown };
}

export class OpenRouterError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

const ENDPOINT = 'https://openrouter.ai/api/v1/chat/completions';

export async function chat(request: ChatRequest): Promise<string> {
  const apiKey = config.openrouter.apiKey;
  if (!apiKey) throw new OpenRouterError(401, 'OPENROUTER_API_KEY is not set.');

  const body: Record<string, unknown> = {
    model: request.model,
    messages: request.messages,
    max_tokens: request.maxTokens ?? 8192,
    // Extraction should be reproducible: the same recording ought to produce
    // the same structure twice.
    temperature: request.temperature ?? 0,
  };

  if (request.jsonSchema) {
    // strict:false keeps this portable. OpenAI's strict mode requires every
    // property to be required with additionalProperties:false, which most
    // other models on OpenRouter do not implement the same way. The response
    // is validated against the real schema regardless, so a model that
    // ignores this hint fails validation rather than corrupting data.
    body.response_format = {
      type: 'json_schema',
      json_schema: { name: request.jsonSchema.name, strict: false, schema: request.jsonSchema.schema },
    };
  }

  const response = await fetch(ENDPOINT, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
      // OpenRouter uses these for attribution on its dashboard.
      'HTTP-Referer': 'https://github.com/hanksvideo07/Ramble',
      'X-Title': 'Ramble',
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(120_000),
  });

  if (!response.ok) {
    const detail = await response.text();
    throw new OpenRouterError(response.status, `OpenRouter returned ${response.status}: ${detail.slice(0, 500)}`);
  }

  const payload = (await response.json()) as {
    choices?: { message?: { content?: string }; finish_reason?: string }[];
    usage?: { prompt_tokens: number; completion_tokens: number };
    model?: string;
  };

  const choice = payload.choices?.[0];
  const content = choice?.message?.content;
  if (!content) throw new OpenRouterError(502, 'OpenRouter returned no message content.');

  // A truncated response is almost always invalid JSON; say so plainly rather
  // than letting it fail as a confusing parse error downstream.
  if (choice?.finish_reason === 'length') {
    throw new OpenRouterError(502, 'Model output was cut off before it finished. Try a shorter section.');
  }

  log.debug('openrouter.usage', {
    model: payload.model,
    prompt_tokens: payload.usage?.prompt_tokens,
    completion_tokens: payload.usage?.completion_tokens,
  });

  return content;
}

/**
 * Pulls the JSON object out of a model response.
 *
 * Small models often wrap JSON in prose or a ```json fence even when asked not
 * to, so the text is salvaged rather than rejected outright.
 */
export function extractJSON(text: string): unknown {
  const trimmed = text.trim();

  try {
    return JSON.parse(trimmed);
  } catch {
    // fall through to salvage
  }

  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fenced?.[1]) {
    try {
      return JSON.parse(fenced[1].trim());
    } catch {
      // fall through
    }
  }

  // Last resort: the outermost {...} span.
  const start = trimmed.indexOf('{');
  const end = trimmed.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      return JSON.parse(trimmed.slice(start, end + 1));
    } catch {
      // fall through
    }
  }

  throw new Error('Model response contained no parsable JSON.');
}
