# Ramble

**Just ramble.** Press one button, talk, and stop thinking about it.

Ramble captures messy speech and turns it into structured understanding —
notes, tasks, ideas, decisions, people, companies — and takes the actions you
asked for. You never decide where anything goes before you say it.

```
VOICE → UNDERSTANDING → MEMORY → ACTION
```

---

## What's here

| | |
|---|---|
| `ios/` | SwiftUI app (iOS 18+). Capture, timeline, search, entity pages. |
| `server/` | TypeScript modular monolith: API, processing pipeline, search. |
| `server/migrations/` | Postgres schema with pgvector and full-text search. |
| `docker-compose.yml` | Postgres + MinIO for local development. |

---

## Running it

### 1. Start the database and object storage

```bash
docker compose up -d
```

Postgres listens on **5434** and MinIO on **9010** (console **9011**), chosen to
avoid colliding with anything already on the usual ports.

### 2. Configure the server

```bash
cp .env.example server/.env
```

It runs with no API keys at all. Every provider falls back to a stand-in, and
anything produced that way is labelled **SAMPLE** in the app rather than passed
off as real. To get genuine understanding, set:

| Variable | What it turns on |
|---|---|
| `ANTHROPIC_API_KEY` | Real extraction and Ask Ramble answers |
| `DEEPGRAM_API_KEY` + `TRANSCRIPTION_PROVIDER=deepgram` | Real transcription |
| `OPENAI_API_KEY` + `EMBEDDING_PROVIDER=openai` | Real semantic search |

Nothing else is required. Calendar and reminders need no keys — they run
on-device through EventKit.

### 3. Run the server

```bash
cd server
npm install
npm run migrate
npm run seed     # optional: a demo account with three worked examples
npm run dev
```

The seed creates `demo@ramble.app` / `rambledemo`, whose timeline shows one
recording becoming a task, an idea, a reminder, and a calendar request.

Check it came up:

```bash
curl -s localhost:8798/v1/health | jq
```

`capabilities` tells you which parts are real and which are stand-ins.

### 4. Run the app

```bash
open ios/Ramble.xcodeproj
```

Build to a simulator and run. The simulator reaches the server on `localhost`
automatically; a physical device needs `RAMBLE_API_URL` set to your Mac's LAN
address.

In a DEBUG build, **Use the demo account** on the sign-in screen fills in the
seeded credentials.

---

## Tests

```bash
cd server && npm test
```

38 tests. The interesting ones are not the unit tests but the behaviors the
product depends on:

- one recording producing many different object types
- a confidently-detected email send still requiring confirmation
- `"Sarah"` resolving to `"Sarah Chen"` — but **not** when two Sarahs exist
- reprocessing being idempotent, and never overwriting a user's correction
- a failed stage leaving the transcript intact and resuming from that stage
- one user's search never reaching another user's data

---

## How it works

### The pipeline

```
audio → transcription → segmentation → understanding → entity resolution
      → embeddings → action detection → confirmation policy → execution
```

Each stage records its own outcome in `processing_stages`. A ramble that fails
at embedding keeps its transcript and extracted items; re-running resumes from
the failed stage rather than starting over. A failed embedding call never costs
you the recording.

Long recordings are sectioned at natural pauses, each section summarized, and
the final synthesis reads the summaries — an hour of speech is never shoved
into one model request.

### Deciding what may happen without asking

The system separates four kinds of statement, because they have different
consequences:

| | Example | |
|---|---|---|
| **information** | "I think we should lower the price." | never acts |
| **intention** | "I need to lower the price." | never acts |
| **explicit action** | "Change the price in the document." | may act |
| **external communication** | "Email Sarah and tell her." | always confirms |

Intent class is checked **before** confidence, deliberately. A hallucinated
intent that the model happens to feel sure about is exactly the failure this
guards against — a model cannot talk its way into sending an email by being
confident. Anything reaching another person is confirmed every time, and that
is not overridable in settings.

### Search

Three systems, fused with Reciprocal Rank Fusion (a BM25 score and a cosine
distance are not on the same scale, so only the orderings are compared):

- **lexical** — Postgres full-text. Exact names and quoted phrases.
- **semantic** — pgvector. Finds *"that insurance company I was pitching"* when
  the transcript only ever says *"Nationwide"*.
- **structured** — entities and item kinds. *"What did I decide about pricing?"*
  ranks decisions above raw transcript.

### Privacy

- Audio lives in private object storage, reached only through short-lived
  signed URLs scoped to one object.
- Every user-owned row carries `user_id` directly, even when it could be reached
  through a join, so a missing join condition cannot leak across users.
- Session tokens are stored only as hashes, and live in the Keychain on device.
- Calendar and reminders are handled entirely on-device. The server knows an
  event was requested and whether it was created — never what is on your
  calendar.
- Logs record identifiers, counts, and latencies. Never transcript text.

---

## API

| | |
|---|---|
| `POST /v1/rambles` | Register a capture (idempotent on `client_id`) |
| `POST /v1/rambles/:id/audio` | Upload audio, start processing |
| `GET /v1/rambles` | Timeline |
| `GET /v1/rambles/:id` | Full detail |
| `GET /v1/search?q=` | Hybrid search |
| `POST /v1/ask` | Ask Ramble, with citations |
| `GET /v1/entities/:id` | Entity page |
| `POST /v1/actions/:id/confirm` | Approve a pending action |
| `GET /v1/inbox` | Everything still waiting on you |
| `POST /v1/webhooks` | Developer webhooks (signed, with retries) |

---

## Capture without opening the app

`StartRambleIntent` is exposed to the Action Button, Control Centre, the lock
screen, and Siri. There is also a `ramble://` URL scheme:

```
ramble://record
ramble://search
ramble://ask?q=What%20did%20I%20decide%20about%20pricing
ramble://ramble/<id>
```

---

## What isn't built yet

Deliberately deferred, in the guide's own priority order:

- Apple Watch capture
- Google Calendar, Gmail, Notion, Obsidian, GitHub (the adapter layer and the
  catalog exist; the OAuth flows do not)
- MCP client, and exposing Ramble's memory over MCP
- Cross-ramble insights, contradiction detection, proactive resurfacing

`email.send`, `integration.invoke`, and `mcp.invoke` fail loudly with a message
telling you to connect the integration, rather than reporting a success that
never happened.
