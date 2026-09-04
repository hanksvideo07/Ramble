You are a senior product engineer, iOS engineer, backend architect, and product designer.

Build a production-quality MVP of an app called RAMBLE.

Do not treat this as a prototype or generic voice-note app. Make sensible product and engineering decisions autonomously when details are unspecified. Optimize for an app that can actually be shipped, tested, and iterated.

==================================================
1. PRODUCT VISION
==================================================

Ramble is a frictionless interface between human thought and software.

Core slogan/concept:

"Just ramble."

A user should be able to press one button and begin speaking naturally without thinking about:
- where the information belongs
- how to organize it
- which app they need
- whether something is a note, task, idea, journal entry, reminder, or action
- how to format it

Ramble captures messy speech and turns it into structured understanding and, where appropriate, actions.

Example:

User presses the iPhone Action Button and says:

"I talked to Sarah at Nationwide today. They seem interested in the enterprise plan, but she needs pricing by Friday. Remind me tomorrow morning to send her the pricing sheet. Also I think we should change the enterprise pitch to emphasize implementation speed. And put a meeting on my calendar Friday afternoon to follow up."

Ramble should be capable of turning this into:

TRANSCRIPT
The complete original transcription.

SUMMARY
Discussion with Sarah at Nationwide regarding enterprise pricing and positioning.

ENTITIES
Sarah
Nationwide
Enterprise plan

TASK
Send Sarah the pricing sheet tomorrow morning.

IDEA
Change enterprise positioning to emphasize implementation speed.

CALENDAR ACTION
Follow up Friday afternoon.

And the original recording/transcript remains searchable forever.

The product is NOT primarily:
- a transcription app
- a voice memo app
- a meeting recorder
- a journaling app
- an AI chat app

Those are capabilities.

The actual product is:

VOICE -> UNDERSTANDING -> MEMORY -> ACTION

==================================================
2. CORE DESIGN PRINCIPLE
==================================================

Capture must be almost frictionless.

The user should never have to decide where information goes BEFORE speaking.

Capture first.
Interpret second.
Organize automatically.
Act where appropriate.

The interface should feel significantly simpler than the underlying system.

Do not expose technical concepts like:
- embeddings
- vector databases
- RAG
- MCP
- tool calling
- schemas

unless the user enters advanced/developer settings.

==================================================
3. PLATFORMS
==================================================

Build iOS first.

Use native Swift / SwiftUI wherever reasonable.

Architecture should also accommodate an Apple Watch app.

Primary capture mechanisms:

1. Main app record button
2. iPhone Action Button via App Intent / Shortcut
3. Lock-screen/widget entry where supported
4. Apple Watch capture
5. Offline recording

ACTION BUTTON FLOW:

Press Action Button
-> Ramble capture immediately appears/starts
-> user speaks
-> user stops
-> recording uploads/processes
-> Ramble handles everything else

Minimize taps.

==================================================
4. OFFLINE-FIRST CAPTURE
==================================================

Recording must not depend on connectivity.

If offline:

1. Record audio locally.
2. Store it safely.
3. Mark recording as awaiting processing.
4. Automatically upload when connectivity returns.
5. Transcribe/process.
6. synchronize results.

This is particularly important for Apple Watch.

The user should be able to ramble while walking/running without their phone nearby and have everything synchronize later.

==================================================
5. TRANSCRIPTION
==================================================

Create a transcription abstraction rather than hard-coding one provider.

Support:

Cloud transcription
AND eventually
On-device transcription

The architecture should make providers swappable.

Requirements:

- strong punctuation
- long-form recordings
- timestamps
- reliable handling of pauses
- background processing
- recording recovery
- language metadata
- high transcription accuracy

Store BOTH:

original audio
original transcript

Never destroy the source material when generating cleaned notes.

==================================================
6. THE UNDERSTANDING LAYER
==================================================

Every completed ramble gets passed through an AI understanding pipeline.

The model should return STRICT STRUCTURED OUTPUT.

Possible extracted object types:

- summary
- note
- idea
- task
- reminder
- decision
- question
- journal entry
- person
- company/organization
- project
- place
- date
- event
- commitment
- follow-up
- link/reference
- action/tool request

One ramble can contain MANY objects.

Example:

A 7-minute ramble might contain:

3 ideas
5 tasks
2 decisions
1 journal thought
4 people
2 companies
1 calendar request

Do NOT force the entire ramble into one category.

Preserve relationships between extracted objects and the source transcript.

==================================================
7. CONFIDENCE + ACTION SAFETY
==================================================

The system must distinguish between:

A. INFORMATION
"I think we should lower the price."

B. INTENTION
"I need to lower the price."

C. EXPLICIT ACTION
"Change the price in the document."

D. EXTERNAL COMMUNICATION
"Email Sarah and tell her we're lowering the price."

These have different consequences.

Implement action confidence.

Low-risk actions can potentially happen automatically.

Examples:
- create internal note
- create task
- categorize thought

Higher-risk actions should require confirmation unless explicitly enabled.

Examples:
- sending email
- deleting something
- changing important calendar events
- external communication

Never let a hallucinated intent create consequential external actions.

==================================================
8. MEMORY MODEL
==================================================

Every Ramble becomes part of a long-term personal memory layer.

Use Postgres as the source of truth.

Suggested entities/tables:

users
rambles
audio_assets
transcripts
transcript_segments
extracted_items
entities
entity_mentions
relationships
actions
integrations
integration_credentials/references
embedding_records

Each Ramble should retain:

id
user_id
created_at
recorded_at
duration
audio reference
raw transcript
clean transcript
summary
processing state
source device
location metadata IF user explicitly permits it
extracted structured objects
entities
embedding references
actions
action results

Use migrations and proper indexes.

==================================================
9. EMBEDDINGS
==================================================

Create embeddings for searchable semantic units.

Do NOT simply create one embedding for an entire giant transcript.

Chunk intelligently by semantic boundaries.

Potential units:

- transcript sections
- extracted notes
- ideas
- decisions
- tasks
- summaries

Store vectors using pgvector or an equivalent architecture.

Embedding provider must be abstracted so models can be changed later.

==================================================
10. SEARCH
==================================================

Search is one of the most important parts of Ramble.

It should feel like searching your own brain.

Support THREE complementary systems:

1. LEXICAL SEARCH
Exact words/names.

2. SEMANTIC SEARCH
Meaning-based retrieval using embeddings.

3. STRUCTURED SEARCH
Entities, dates, types, projects, people, companies, etc.

Combine these into hybrid search.

Examples:

"Nationwide"

Returns:
- Nationwide entity page
- rambles mentioning Nationwide
- tasks involving Nationwide
- people associated with Nationwide
- decisions involving Nationwide

"that insurance company I was pitching"

Semantic search should find Nationwide even if those exact words aren't present.

"What did I decide about enterprise pricing?"

Retrieve relevant DECISIONS rather than blindly dumping transcript chunks.

"things I've said about onboarding"

Retrieve semantically relevant excerpts across multiple rambles.

==================================================
11. ENTITY PAGES
==================================================

Automatically create evolving entity pages.

Examples:

Nationwide
Sarah Chen
Ramble
Project Atlas

A company page might contain:

NATIONWIDE

Overview
Automatically generated from memory.

Recent Activity

September 3
Discussed enterprise pricing.

August 29
Sarah requested implementation details.

Open Tasks
Send pricing proposal.

Decisions
Lead with implementation speed.

Related People
Sarah Chen

Related Rambles
[chronological list]

These pages should update as new information arrives.

Do not generate thousands of junk entities.

Use entity resolution to recognize that repeated mentions refer to the same entity.

==================================================
12. ASK RAMBLE
==================================================

Provide a conversational search interface.

Example:

"What have I said about Nationwide?"

"What ideas have I had about Ramble?"

"What promises did I make this week?"

"What have I been thinking about most recently?"

"Find the thing I said about changing our onboarding."

"What decisions have I made about pricing?"

Answers MUST be grounded in retrieved user data.

Provide links back to source Rambles.

The system should make it easy to inspect exactly where an answer came from.

==================================================
13. TIMELINE
==================================================

The default home experience should probably be a chronological timeline.

Each Ramble card should show:

time
short AI-generated title
summary
important extracted objects
actions performed

Example:

8:42 PM

Nationwide follow-up

Discussed pricing with Sarah and decided to emphasize implementation speed.

[2 Tasks] [1 Idea] [Nationwide]

Tap -> full Ramble.

==================================================
14. RAMBLE DETAIL VIEW
==================================================

Show:

AI title
summary
recording player
full transcript
extracted items
entities
actions
related Rambles

Allow user corrections.

For example:

"This isn't a task."

"This is related to Nationwide."

"Sarah Chen and Sarah are the same person."

These corrections should update stored structured data.

Architect the system so corrections could later become useful personalization signals.

==================================================
15. INTEGRATIONS
==================================================

Integrations are central to the product.

Users should NOT need to understand MCP.

Normal users should see:

Connect Google Calendar
Connect Gmail
Connect Obsidian
Connect GitHub
Connect Claude/workflows
etc.

OAuth where appropriate.

Potential integrations:

Calendar
- Apple Calendar
- Google Calendar

Tasks
- Apple Reminders
- Todoist

Notes
- Obsidian
- Notion

Development
- GitHub
- Codex-oriented workflows

Communication
- Gmail
- eventually Slack

Automation
- webhooks
- MCP

Build the integration architecture around normalized internal actions.

Example internal tool:

calendar.create_event()

Then adapters can implement:

GoogleCalendarAdapter
AppleCalendarAdapter

Do not make the LLM responsible for knowing provider-specific APIs.

==================================================
16. MCP
==================================================

MCP should be an ADVANCED feature.

Ramble should be capable of acting as an MCP client so sophisticated users can connect arbitrary MCP servers/tools.

Potential future possibility:

Expose Ramble memory itself through MCP so external AI agents can query the user's Ramble database with explicit user authorization.

Example:

Codex could potentially ask:

"What has the user previously said about authentication architecture for this project?"

Design interfaces so this is possible later.

Do not overbuild it if it jeopardizes the MVP.

==================================================
17. WEBHOOKS
==================================================

Provide developer webhooks.

Potential events:

ramble.created
ramble.transcribed
ramble.processed
task.created
idea.created
action.requested
action.completed

Allow configurable webhook endpoints.

Include signatures/authentication and retry behavior.

==================================================
18. ACTION ENGINE
==================================================

Create a normalized action system.

Example:

{
  type: "calendar.create_event",
  parameters: {...},
  confidence: 0.97,
  requires_confirmation: false
}

Other possible actions:

reminder.create
task.create
note.create
email.draft
email.send
calendar.create_event
calendar.update_event
webhook.trigger
integration.invoke
mcp.invoke

Every action should have lifecycle state:

detected
awaiting_confirmation
approved
executing
completed
failed
cancelled

Store action history.

==================================================
19. PROCESSING PIPELINE
==================================================

Conceptually:

AUDIO
  ↓
TRANSCRIPTION
  ↓
SEGMENTATION
  ↓
UNDERSTANDING / STRUCTURED EXTRACTION
  ↓
ENTITY RESOLUTION
  ↓
EMBEDDINGS
  ↓
DATABASE
  ↓
ACTION DETECTION
  ↓
CONFIRMATION POLICY
  ↓
TOOL EXECUTION
  ↓
RESULT
  ↓
MEMORY UPDATE

Processing should be asynchronous and resumable.

Do not make a failed embedding call cause the entire Ramble to disappear.

Each stage should have observable state and retry behavior.

==================================================
20. LONG RAMBLES
==================================================

The application must support substantial recordings.

Do not assume every capture is 30 seconds.

Design for:

10 seconds
2 minutes
20 minutes
60+ minutes

For long recordings:

chunk transcription
maintain timestamps
segment by topic
generate section summaries
then generate higher-level synthesis

Do not shove arbitrarily large transcripts into a single model request.

==================================================
21. PERSONALIZATION
==================================================

Onboarding asks something lightweight like:

"What best describes you?"

Student
Founder
Executive
Creator
Developer
Other

This should NOT fundamentally change the product.

It should change sensible defaults.

Example:

STUDENT
Extract:
assignments
deadlines
study ideas

FOUNDER
Extract:
customers
companies
product ideas
follow-ups
decisions

EXECUTIVE
Extract:
delegations
meetings
people
commitments

The universal data model remains the same.

==================================================
22. ONBOARDING
==================================================

Keep onboarding extremely short.

Explain the central behavior:

"Don't organize. Just ramble."

Then:

1. choose basic profile/defaults
2. microphone permission
3. notifications if useful
4. optional integrations
5. teach Action Button setup where applicable

Get them to their FIRST RAMBLE as quickly as possible.

==================================================
23. DESIGN
==================================================

The design should be extremely polished and calm.

Think:
Apple-native
Linear-level restraint
Notion-level information density where appropriate

Avoid:
AI gradients everywhere
chatbot clichés
huge amounts of UI chrome
complex dashboards
technical terminology

The record button is the hero.

The product should feel almost suspiciously simple.

Primary navigation could be approximately:

Home
Search
Ramble

with Settings accessible separately.

Feel free to improve this.

==================================================
24. RECORDING UX
==================================================

Recording screen should prioritize speaking.

Show:

recording duration
simple waveform/activity visualization
stop button

Potentially show live transcription if technically sensible, but DO NOT let live transcription compromise recording reliability.

Audio recording is the source of truth.

After stopping:

Immediately return the user to normal usage.

Show processing state asynchronously.

Do not force the user to stare at a loading spinner while AI processing completes.

==================================================
25. PRIVACY
==================================================

This application stores extremely sensitive personal information.

Treat privacy as a first-class architectural requirement.

Implement:

encryption in transit
secure authentication
proper credential storage
strict per-user authorization
private object storage
signed URLs where appropriate
deletion workflows
data export architecture

Never leak one user's embeddings/search results into another user's retrieval.

Cloud transcription should be clearly disclosed.

Architect for future on-device/private processing.

==================================================
26. AI ARCHITECTURE
==================================================

Do NOT scatter model calls throughout the codebase.

Create provider abstractions such as:

TranscriptionProvider
EmbeddingProvider
UnderstandingProvider
AnswerProvider

Use structured schemas for extraction.

Validate model output before writing consequential data.

Keep prompts versioned.

Store enough metadata to debug processing failures.

==================================================
27. TECHNOLOGY
==================================================

Preferred architecture:

CLIENT
SwiftUI
Swift
AVFoundation
App Intents
WatchKit / watchOS architecture where appropriate

BACKEND
Choose a pragmatic TypeScript backend.

DATABASE
Postgres
pgvector

STORAGE
S3-compatible object storage

AI
Provider abstractions.

AUTH
Secure managed authentication.

BACKGROUND PROCESSING
Use an appropriate durable job/queue system.

Do not introduce microservices unnecessarily.

A modular monolith is preferable for v1.

==================================================
28. OBSERVABILITY
==================================================

Add basic production observability.

Track:

recording created
upload success/failure
transcription latency
processing latency
model failures
action failures
search latency

Use structured logging.

Never log private transcript contents unnecessarily.

==================================================
29. ANALYTICS
==================================================

Instrument important product events:

onboarding_completed
first_ramble_created
ramble_created
ramble_processed
search_performed
search_result_opened
action_detected
action_confirmed
action_completed
integration_connected

We want to eventually understand:

time-to-first-Ramble
Rambles/user/week
search usage
actions/Ramble
successful action rate
retention

==================================================
30. MVP PRIORITY
==================================================

Do NOT attempt every integration before the core loop works.

P0:

- authentication
- iOS recording
- Action Button/App Intent capture
- offline-safe recording/upload
- cloud transcription
- transcript storage
- structured extraction
- timeline
- Ramble detail
- embeddings
- hybrid search
- entity extraction
- entity pages
- Ask Ramble
- action extraction
- basic action confirmation UX
- one excellent calendar/reminder integration
- polished onboarding
- settings
- privacy/security fundamentals

P1:

- Apple Watch
- additional integrations
- webhooks
- advanced MCP
- Obsidian
- GitHub/Codex workflows
- more sophisticated personalization

P2:

- sophisticated cross-Ramble insights
- contradiction detection
- automatic project creation
- proactive resurfacing
- deeper personal knowledge graph
- external agent access to Ramble memory

==================================================
31. IMPORTANT PRODUCT JUDGMENT
==================================================

Do NOT turn Ramble into a generic AI productivity dashboard.

The magic is:

PRESS
SPEAK
DONE

Everything downstream exists to preserve that experience.

When deciding whether to add UI, ask:

"Does the user actually need to make this decision?"

If AI can safely infer it, infer it.

If Ramble can safely organize it, organize it.

If Ramble can safely execute it, execute it.

Only interrupt the user when ambiguity or consequences justify interruption.

==================================================
32. FIRST-RUN DEMO
==================================================

Create a great sample/demo Ramble so the product's value is immediately obvious.

Example:

"I need to finish the history paper by Thursday. Also remind me tomorrow to ask Ben about the startup competition. I've been thinking we should change Ramble's onboarding so people actually make their first recording before connecting integrations. Oh, and put practice on my calendar Wednesday at 4."

Visually demonstrate how this becomes multiple structured objects.

This teaches the product better than explanatory onboarding screens.

==================================================
33. BUILD PROCESS
==================================================

Before implementing:

1. Inspect the repository.
2. Write a concise architecture plan.
3. Define the database schema.
4. Define the structured extraction schema.
5. Define the action/tool interface.
6. Define the search architecture.
7. Define the iOS navigation/state architecture.
8. Identify external credentials that cannot be generated automatically.

Then implement.

Do not stop after scaffolding.

Build the application end-to-end as far as the environment allows.

Create:
- migrations
- backend
- API
- iOS client
- recording system
- AI pipeline
- search
- integration abstraction
- tests
- setup documentation
- .env.example

Use mock adapters ONLY where real credentials make implementation impossible.

Clearly separate mocked behavior from production behavior.

==================================================
34. TESTING
==================================================

Test the important behavior, not merely trivial functions.

Especially test:

- one Ramble producing multiple object types
- entity resolution
- hybrid search
- action confidence
- destructive/external action confirmation
- failed processing retry
- offline recording recovery
- duplicate processing/idempotency
- user isolation
- long transcript chunking
- malformed model structured output
- calendar action execution

==================================================
35. SUCCESS CRITERIA
==================================================

The MVP succeeds if this experience works:

I pull out my phone.

I press the Action Button.

I speak naturally for 90 seconds about five unrelated things.

I stop.

I do nothing else.

Later I open Ramble.

My thoughts have become organized notes, ideas, tasks, entities, and actions.

The correct calendar/reminder actions happened or were queued for confirmation.

Two weeks later I search:

"What was that idea I had about onboarding?"

Ramble finds it immediately.

Three months later I ask:

"What have I said about Nationwide and what do I still owe them?"

Ramble synthesizes the relevant history, open commitments, people, decisions, and source recordings.

At no point did I have to manually organize any of it.

That is the product.

Build Ramble.