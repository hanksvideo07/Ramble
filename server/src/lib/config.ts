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
    /**
     * Extraction is the safety-critical call: it decides whether something was
     * a musing or an instruction. Chosen by measuring exactly that, not by
     * price or size — see `npm run eval:models`.
     *
     * Measured over the four intent classes: nemotron produced valid JSON
     * every time and never misread a statement in the dangerous direction.
     * gpt-oss-20b is cheaper but read "Email Sarah and tell her" as a direct
     * instruction rather than an outbound message. gpt-5-nano is unusable
     * here at any price: it spends its entire token budget on reasoning and
     * returns empty content.
     */
    understandingModel: optional('UNDERSTANDING_MODEL', 'nvidia/nemotron-3-nano-30b-a3b'),

    /**
     * Routing policy applied to every request.
     *
     * This app sends people's unedited private thoughts to a third party, so
     * where that goes and what happens to it afterwards is a product
     * requirement, not a preference.
     */
    routing: {
      /**
       * Only route to providers that do not store or train on prompts.
       * OpenRouter enforces this itself and will fail the request rather than
       * fall back to a provider that retains data.
       */
      denyDataCollection: optional('OPENROUTER_DENY_DATA_COLLECTION', 'true') === 'true',

      /**
       * Providers excluded on geography. Derived from OpenRouter's own
       * provider metadata — headquarters in CN, or any datacenter in CN —
       * rather than guessed. Re-derive with `npm run providers:audit`, which
       * fails if this list has drifted from what OpenRouter reports.
       */
      ignoredProviders: optional(
        'OPENROUTER_IGNORED_PROVIDERS',
        'streamlake,alibaba,baidu,deepseek,tencent,xiaomi,nex-agi',
      )
        .split(',')
        .map((p) => p.trim())
        .filter(Boolean),

      /**
       * Refuse providers that do not implement every parameter sent. Several
       * endpoints serve the same model without structured-output support, and
       * silently landing on one degrades extraction rather than failing it.
       */
      requireParameters: optional('OPENROUTER_REQUIRE_PARAMETERS', 'true') === 'true',
    },
    // Answering only summarizes excerpts that were already retrieved, so it
    // cannot trigger an action and can run on the same cheap model.
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
    // 'device' | 'openrouter' | 'openai' | 'mock'. Switching this changes the
    // vector space, so EMBEDDING_REVISION must be bumped with it or old
    // vectors will be searched as if they were comparable.
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
    // Transcription normally happens on the device; this is only what the
    // server would fall back to for a recording that arrives without one.
    transcription_fallback:
      config.transcription.provider === 'deepgram' && config.transcription.deepgramKey
        ? 'deepgram'
        : config.transcription.provider === 'openai' && config.transcription.openaiKey
          ? 'openai'
          : 'mock',
    embedding:
      config.embedding.provider === 'device'
        ? `device:${config.embedding.model}@${config.embedding.deviceRevision}`
        : config.embedding.provider === 'openai' && config.embedding.openaiKey
          ? 'openai'
          : 'mock',
    calendar: 'apple_local+google_stub',
    // Whether the higher-accuracy option is worth offering in the app.
    cloud_transcription:
      (config.transcription.provider === 'deepgram' && Boolean(config.transcription.deepgramKey)) ||
      (config.transcription.provider === 'openai' && Boolean(config.transcription.openaiKey))
        ? 'available'
        : 'unavailable',
  };
}
