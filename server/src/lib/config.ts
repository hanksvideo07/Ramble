import 'dotenv/config';

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var ${name}. See .env.example.`);
  return value;
}

function optional(name: string, fallback = ''): string {
  return process.env[name] ?? fallback;
}

function int(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (Number.isNaN(parsed)) throw new Error(`Env var ${name} must be an integer, got "${raw}".`);
  return parsed;
}

export const config = {
  env: optional('NODE_ENV', 'development'),
  port: int('PORT', 8787),
  logLevel: optional('LOG_LEVEL', 'info'),

  databaseUrl: required('DATABASE_URL'),

  /**
   * Absolute URL this server is reachable at. Used to build audio playback
   * links, which must be absolute because the player fetches them directly.
   * Railway supplies the public domain at runtime.
   */
  publicUrl:
    process.env.PUBLIC_URL ||
    (process.env.RAILWAY_PUBLIC_DOMAIN ? `https://${process.env.RAILWAY_PUBLIC_DOMAIN}` : '') ||
    `http://localhost:${int('PORT', 8787)}`,

  storage: {
    /**
     * When set, audio is stored in this directory instead of S3. Intended for
     * a deployment with a persistent volume and no object store.
     */
    directory: optional('AUDIO_DIR'),
  },

  // A dev fallback keeps `npm run dev` working out of the box; production
  // refuses to start without a real secret.
  authSecret:
    process.env.AUTH_SECRET ||
    (process.env.NODE_ENV === 'production'
      ? required('AUTH_SECRET')
      : 'dev-only-insecure-secret'),

  s3: {
    endpoint: optional('S3_ENDPOINT', 'http://localhost:9010'),
    region: optional('S3_REGION', 'us-east-1'),
    bucket: optional('S3_BUCKET', 'ramble-audio'),
    accessKeyId: optional('S3_ACCESS_KEY_ID', 'rambleminio'),
    secretAccessKey: optional('S3_SECRET_ACCESS_KEY', 'rambleminio'),
    forcePathStyle: optional('S3_FORCE_PATH_STYLE', 'true') === 'true',
    signedUrlTtl: int('S3_SIGNED_URL_TTL', 3600),
  },

  openrouter: {
    apiKey: optional('OPENROUTER_API_KEY'),
    // Extraction is the safety-critical call: it decides whether something was
    // a musing or an instruction. Schema adherence and instruction-following
    // matter more here than model size, which is why the default is a small
    // model known for both rather than the outright cheapest.
    understandingModel: optional('UNDERSTANDING_MODEL', 'openai/gpt-5-nano'),
    // Answering is lighter work — summarize retrieved excerpts — so it can run
    // on something cheaper without risking a wrong action.
    answerModel: optional('ANSWER_MODEL', 'nvidia/nemotron-3-nano-30b-a3b'),
  },

  transcription: {
    provider: optional('TRANSCRIPTION_PROVIDER', 'mock'),
    deepgramKey: optional('DEEPGRAM_API_KEY'),
    openaiKey: optional('OPENAI_API_KEY'),
  },

  embedding: {
    // 'device' means the client embeds; the server never calls an embedding
    // API and simply stores what the device computes.
    provider: optional('EMBEDDING_PROVIDER', 'device'),
    model: optional('EMBEDDING_MODEL', 'apple.nl_contextual'),
    // Must match the width the device produces, or vectors are incomparable.
    dimension: int('EMBEDDING_DIMENSION', 512),
    deviceRevision: int('EMBEDDING_REVISION', 1),
    openaiKey: optional('OPENAI_API_KEY'),
  },

  google: {
    clientId: optional('GOOGLE_CLIENT_ID'),
    clientSecret: optional('GOOGLE_CLIENT_SECRET'),
    redirectUri: optional('GOOGLE_REDIRECT_URI'),
  },

  webhookSigningSecret: optional('WEBHOOK_SIGNING_SECRET', 'dev-webhook-secret'),
} as const;

/**
 * Which capabilities are backed by a real provider. Surfaced at /v1/health and
 * in the iOS settings screen so mocked behavior is never mistaken for real.
 */
export function capabilityReport() {
  return {
    understanding: config.openrouter.apiKey ? `openrouter:${config.openrouter.understandingModel}` : 'mock',
    answering: config.openrouter.apiKey ? `openrouter:${config.openrouter.answerModel}` : 'mock',
    transcription:
      config.transcription.provider === 'deepgram' && config.transcription.deepgramKey
        ? 'deepgram'
        : config.transcription.provider === 'openai' && config.transcription.openaiKey
          ? 'openai'
          : 'mock',
    embedding:
      config.embedding.provider === 'openai' && config.embedding.openaiKey ? 'openai' : 'mock',
    calendar: 'apple_local+google_stub',
  };
}
