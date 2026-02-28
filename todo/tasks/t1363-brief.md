---
mode: subagent
---
# t1363: Conversational Memory and Entity Relationship System for Multi-Channel Agents

## Origin

- **Created:** 2026-02-27
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human)
- **Conversation context:** Discussion about OpenClaw-style conversation persistence layers, evaluating whether flat-file pre-compact dumps are valuable. Concluded the problem is real (compaction kills conversational continuity) but the solution needs to be architectural, not flat files. Extended into vision for multi-channel agents (Matrix, SimpleX, email, DMs) where the system maintains relationship continuity with individuals across all channels — and self-evolves capabilities based on observed needs.

## What

A two-layer memory system that gives aidevops multi-channel agents the ability to:

1. **Maintain per-conversation context** — what's being discussed right now in this specific thread, on this specific channel, with the tone and flow intact across compaction boundaries and session resets.

2. **Build entity relationship models** — accumulated understanding of each person/agent the system interacts with, across ALL channels and ALL time, including inferred needs, expectations, communication preferences, and capability gaps.

3. **Self-evolve from relationship patterns** — when the system detects repeated needs, friction points, or capability gaps across entity interactions, it automatically creates TODO tasks to upgrade itself.

4. **Remain model/provider-agnostic** — the memory, continuity, and relationship quality must be consistent regardless of which base model (Opus, Sonnet, Haiku, Gemini, local llama.cpp) is handling a given conversation. The memory layer IS the continuity — not the model's context window.

5. **Treat memories as immutable source of truth** — raw interaction data is append-only and never edited. Contextual distillation (summaries, inferred needs, pattern extraction) exists as derived layers that always reference back to source records. History is precious and must be accurately retained.

### The Immutability Principle

This is a core architectural constraint, not a nice-to-have:

- **Raw messages**: Append-only. Never edited, never deleted (except by explicit user request for privacy). These are the source of truth.
- **Conversation summaries**: Derived from raw messages. Always link back to the message range they summarise. If a summary is wrong, create a new one — don't edit the old one.
- **Entity profiles**: Derived from interaction history. Changes are versioned (using the existing `updates`/`extends`/`derives` relation types from Supermemory-inspired memory system). The full derivation chain is preserved.
- **Inferred needs/expectations**: Tagged with confidence levels and the evidence (message IDs) that produced the inference. Can be superseded but never silently overwritten.
- **Capability gap tasks**: Created with full evidence trail linking back to the entity interactions that revealed the gap.

This means any layer of contextual distillation — from raw messages to conversation summaries to entity profiles to inferred needs — can be traced back to its source. A model can re-derive any higher layer from the raw data if needed.

## Why

### Immediate problem
Current aidevops memory is project-scoped and content-typed. It knows "CORS was fixed with nginx headers" but has no concept of "Marcus prefers concise responses and repeatedly asks about deployment status." The Matrix bot has per-room sessions with fixed 300s idle timeout compaction, but no cross-channel entity awareness.

### Strategic problem
aidevops is heading toward multi-channel persistent agents (Matrix rooms, SimpleX DMs, email threads, chat channels, chatbots). Without entity-scoped memory, each channel interaction starts from zero relationship context. A person who's had 50 conversations across Matrix and SimpleX would feel like they're talking to a stranger every time.

### UX north star
The benchmark is "an attentive person" — someone who remembers what you discussed, knows your preferences, picks up where you left off, and proactively anticipates what you need. Not a system that "knows facts about you" but one that maintains genuine conversational and relational continuity. This quality must hold regardless of which model is behind the conversation on any given day.

### Agent-to-agent relationships
Entities include other AI agents (`entity_type: agent`), not just people. As aidevops instances communicate across machines via SimpleX/Matrix mail transports, they build relationship models of each other — capabilities, reliability, response patterns. This enables intelligent routing ("agent X is better at SEO tasks") and collaborative memory ("agent X discovered this pattern while working on project Y"). This is a future extension of the core entity system, not a Phase 1 requirement.

### The self-evolution gap
Nobody in the AI agent space is doing "the system files tasks to upgrade itself based on patterns in user interactions." Every chatbot does conversation memory. The differentiator is: entity interaction patterns → capability gap detection → automatic TODO creation → system upgrade → better service → updated entity model. This is the feedback loop that makes the system compound over time.

### Model-agnosticism as resilience
Models and providers change. Context windows vary. Costs fluctuate. The memory layer must be the source of continuity, not the model's context window. Whether today's conversation is handled by Opus and tomorrow's by a local Qwen model, the entity relationship and conversation history must provide equivalent continuity. This also means the summarisation and distillation must be high-quality enough that a less capable model can still provide good service when primed with the right context.

### Deterministic-to-intelligent upgrades
Several existing systems use hardcoded thresholds where intelligence would be better:
- Matrix bot: `sessionIdleTimeout: 300` (fixed 5min) — should be "has this conversation naturally paused?"
- Memory pruning: `DEFAULT_MAX_AGE_DAYS=90` — should be "is this memory still relevant given what we know about the entity?"
- Memory dedup: exact string matching — should be "are these semantically the same insight?"
- Session compaction: token-count-based — should be "what's worth preserving from this conversation for this entity?"

## How (Approach)

### Architecture: Three-Layer Model

```text
Layer 0: RAW INTERACTION LOG (immutable, append-only)
├── Every message sent/received across all channels
├── Metadata: timestamp, channel, entity_id, direction, message_type
├── Never edited, never summarised in-place
├── Source of truth for all derived layers
└── Retention: indefinite (user can request deletion for privacy)

Layer 1: PER-CONVERSATION CONTEXT (tactical, derived from Layer 0)
├── Active threads per channel/entity combination
├── Recent exchange summaries (derived, link back to Layer 0 message ranges)
├── Tone/style profile for this conversation
├── Pending actions from THIS conversation
├── Channel-specific metadata
└── Lifecycle: active during conversation, archived on idle, resumable

Layer 2: ENTITY RELATIONSHIP MODEL (strategic, derived from Layers 0+1)
├── Identity: who they are, channel map (Matrix + SimpleX + email = same person)
├── Interaction history: summarised patterns over time (versioned, not overwritten)
├── Inferred needs: what they repeatedly ask for, struggle with, care about
├── Expectations: response time, depth, format, technical level
├── Capability gaps: things they needed that the system couldn't do
├── Satisfaction signals: what worked well, what caused friction
└── Lifecycle: long-lived, continuously enriched, never reset
```

### Self-Evolution Loop

```text
Entity interactions (Layer 0)
    → Pattern detection (Layer 2: inferred needs, repeated friction)
    → Capability gap identification (AI judgment, not regex)
    → TODO creation with evidence trail (message IDs, entity context)
    → System upgrade (normal aidevops task lifecycle)
    → Better service to entity
    → Updated entity model (Layer 2)
    → Cycle continues
```

### SQLite Schema Extension

Extend the existing `memory.db` with new tables (not a separate database — entity memories should be searchable alongside project memories):

```sql
-- Layer 0: Raw interaction log
CREATE TABLE interactions (
    id TEXT PRIMARY KEY,           -- int_XXXXXXXX
    entity_id TEXT NOT NULL,       -- ent_XXXXXXXX
    channel_type TEXT NOT NULL,    -- matrix|simplex|email|cli|dm
    channel_id TEXT NOT NULL,      -- room ID, contact ID, email thread, etc.
    direction TEXT NOT NULL,       -- inbound|outbound
    content TEXT NOT NULL,         -- raw message content
    message_type TEXT DEFAULT 'text', -- text|voice|file|reaction|command
    metadata TEXT,                 -- JSON: attachments, reply-to, etc.
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id)
);

-- Entity identity and cross-channel linking
CREATE TABLE entities (
    id TEXT PRIMARY KEY,           -- ent_XXXXXXXX
    display_name TEXT,             -- human-readable name
    entity_type TEXT DEFAULT 'person', -- person|agent|service|group
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Channel handles for identity resolution
CREATE TABLE entity_channels (
    id TEXT PRIMARY KEY,
    entity_id TEXT NOT NULL,
    channel_type TEXT NOT NULL,    -- matrix|simplex|email|cli
    channel_handle TEXT NOT NULL,  -- @user:server, contact-id, email@addr
    verified INTEGER DEFAULT 0,   -- 0=inferred, 1=confirmed by user
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id),
    UNIQUE(channel_type, channel_handle)
);

-- Layer 1: Conversation sessions
CREATE TABLE conversations (
    id TEXT PRIMARY KEY,           -- conv_XXXXXXXX
    entity_id TEXT NOT NULL,
    channel_type TEXT NOT NULL,
    channel_id TEXT NOT NULL,
    status TEXT DEFAULT 'active',  -- active|idle|archived
    summary TEXT,                  -- AI-generated summary (derived, references message range)
    summary_source_range TEXT,     -- "int_XXX..int_YYY" — which messages the summary covers
    tone_profile TEXT,             -- JSON: formality, technical_level, pace
    pending_actions TEXT,          -- JSON array of commitments made
    started_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    last_activity_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    archived_at TEXT,
    FOREIGN KEY (entity_id) REFERENCES entities(id)
);

-- Layer 2: Entity relationship model (versioned via existing relation system)
CREATE TABLE entity_profiles (
    id TEXT PRIMARY KEY,           -- ep_XXXXXXXX
    entity_id TEXT NOT NULL,
    profile_type TEXT NOT NULL,    -- needs|expectations|preferences|gaps|satisfaction
    content TEXT NOT NULL,         -- the insight/observation
    confidence TEXT DEFAULT 'medium', -- low|medium|high
    evidence TEXT,                 -- JSON array of interaction IDs that support this
    supersedes_id TEXT,            -- previous version of this profile entry
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id)
);

-- Capability gaps detected from entity interactions
CREATE TABLE capability_gaps (
    id TEXT PRIMARY KEY,           -- gap_XXXXXXXX
    entity_id TEXT,                -- which entity revealed this (nullable for system-wide)
    description TEXT NOT NULL,
    evidence TEXT,                 -- JSON array of interaction IDs
    frequency INTEGER DEFAULT 1,  -- how many times this gap was observed
    todo_task_id TEXT,             -- t1XXX if a task was created
    status TEXT DEFAULT 'detected', -- detected|task_created|resolved
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    resolved_at TEXT,
    FOREIGN KEY (entity_id) REFERENCES entities(id)
);

-- FTS5 index for interaction content search
CREATE VIRTUAL TABLE interactions_fts USING fts5(
    content,
    entity_id UNINDEXED,
    channel_type UNINDEXED,
    created_at UNINDEXED,
    tokenize='porter unicode61'
);
```

### Identity Resolution

The hardest sub-problem. Same person across Matrix (`@marcus:server`), SimpleX (contact ID), email (`marcus@domain`):

- **Automatic linking**: When a Matrix profile contains an email that matches an existing entity's email channel, suggest linking.
- **Explicit linking**: User or admin confirms "these are the same person" via CLI command.
- **Contextual clues**: AI judgment — if someone on SimpleX discusses the same project with the same terminology as someone on Matrix, flag for review (never auto-link without confirmation).
- **Privacy boundaries**: Entity profiles track which information came from which channel. Information from a private SimpleX DM is never surfaced in a public Matrix room unless the entity has explicitly shared it there too.

### Privacy-Aware Context Loading

When loading entity context for a conversation:

```text
1. Load conversation-specific context (Layer 1) — always safe
2. Load entity profile (Layer 2) — filter by channel privacy:
   - Public channel info → available everywhere
   - Private channel info → only available in same-privacy-level channels
   - User-confirmed shared info → available everywhere
3. Never cross privacy boundaries without explicit entity consent
```

### Deterministic-to-Intelligent Upgrades

Replace hardcoded thresholds with AI judgment calls (haiku-tier, cheap):

| Current | Replacement | Model tier |
|---------|-------------|------------|
| `sessionIdleTimeout: 300` | AI judges "has this conversation naturally concluded?" based on last few messages | haiku |
| `DEFAULT_MAX_AGE_DAYS=90` prune | AI judges "is this memory still relevant to any active entity relationship?" | haiku |
| Exact-string dedup | Semantic similarity check (existing embeddings infrastructure) | local embeddings |
| Fixed compaction at token limit | AI judges "what from this conversation is worth preserving for this entity's profile?" | sonnet |
| Fixed `maxPromptLength: 4000` | Dynamic based on entity's observed preference for detail level | haiku |

### Integration Points

- **Matrix bot** (`matrix-dispatch-helper.sh`): Replace per-room SQLite sessions with Layer 0/1 tables. Entity resolution from Matrix user IDs.
- **SimpleX bot** (`simplex-helper.sh`): Same pattern. Entity resolution from SimpleX contact IDs.
- **Email** (future): Parse email threads into Layer 0 interactions. Entity resolution from email addresses.
- **CLI sessions** (current): Optionally log interactive session exchanges as Layer 0 interactions for the "user" entity.
- **Memory system** (`memory-helper.sh`): Add `--entity` flag to store/recall for entity-scoped queries. Existing project-scoped memories remain unchanged.
- **Pulse supervisor**: New phase — "entity pattern scan" — reviews recent interactions across entities, detects capability gaps, creates TODOs.

### Key Files to Modify

- `scripts/memory-helper.sh` + `scripts/memory/` — add entity dimension, new tables, entity-scoped queries
- `scripts/memory/_common.sh` — schema migration for new tables
- `services/communications/matrix-bot.md` — update session model to use Layer 0/1
- `services/communications/simplex.md` — same
- `memory/README.md` — document entity memory system
- `scripts/commands/pulse.md` — add entity pattern scan phase

### Key Files to Create

- `scripts/entity-helper.sh` — entity CRUD, identity resolution, profile management, gap detection
- `scripts/conversation-helper.sh` — conversation lifecycle, context loading, privacy filtering
- `reference/entity-memory-architecture.md` — architecture doc for the three-layer model
- `templates/entity-profile-template.md` — template for entity profile display

## Acceptance Criteria

- [ ] Layer 0: Raw interactions are stored immutably with entity_id, channel, direction, timestamp
  ```yaml
  verify:
    method: bash
    run: "sqlite3 ~/.aidevops/.agent-workspace/memory/memory.db '.tables' | grep -q interactions"
  ```
- [ ] Layer 0: No UPDATE or DELETE operations exist in code paths touching the interactions table (except explicit user privacy deletion)
  ```yaml
  verify:
    method: codebase
    pattern: "UPDATE interactions|DELETE FROM interactions"
    path: ".agents/scripts/"
    expect: absent
  ```
- [ ] Layer 1: Conversations track active threads per entity+channel with AI-judged idle detection (not fixed timeout)
  ```yaml
  verify:
    method: codebase
    pattern: "conversations"
    path: ".agents/scripts/conversation-helper.sh"
  ```
- [ ] Layer 1: Conversation summaries always reference the source message range they were derived from
  ```yaml
  verify:
    method: codebase
    pattern: "summary_source_range"
    path: ".agents/scripts/"
  ```
- [ ] Layer 2: Entity profiles are versioned (supersedes_id chain), never overwritten in place
  ```yaml
  verify:
    method: codebase
    pattern: "supersedes_id"
    path: ".agents/scripts/entity-helper.sh"
  ```
- [ ] Layer 2: Inferred needs include confidence level and evidence (interaction IDs)
  ```yaml
  verify:
    method: codebase
    pattern: "evidence.*confidence"
    path: ".agents/scripts/entity-helper.sh"
  ```
- [ ] Identity resolution: entities can be linked across channels with verified/unverified status
  ```yaml
  verify:
    method: bash
    run: "sqlite3 ~/.aidevops/.agent-workspace/memory/memory.db 'SELECT sql FROM sqlite_master WHERE name=\"entity_channels\"' | grep -q verified"
  ```
- [ ] Privacy: channel-level privacy filtering prevents cross-channel information leakage
  ```yaml
  verify:
    method: codebase
    pattern: "privacy\|channel.*filter\|private.*channel"
    path: ".agents/scripts/conversation-helper.sh"
  ```
- [ ] Self-evolution: capability gaps detected from entity interactions create TODO tasks with evidence
  ```yaml
  verify:
    method: codebase
    pattern: "capability_gap\|todo_task_id"
    path: ".agents/scripts/entity-helper.sh"
  ```
- [ ] Model-agnostic: memory/context loading works regardless of which model handles the conversation
  ```yaml
  verify:
    method: subagent
    prompt: "Review entity-helper.sh and conversation-helper.sh. Verify that context loading produces a model-agnostic prompt (plain text with structured context) rather than relying on any model-specific features."
  ```
- [ ] Existing memory system (`/remember`, `/recall`) continues to work unchanged
  ```yaml
  verify:
    method: bash
    run: "~/.aidevops/agents/scripts/memory-helper.sh recall --query 'test' --limit 1 2>&1; echo $?"
  ```
- [ ] At least one deterministic threshold replaced with AI judgment (sessionIdleTimeout or prune age)
  ```yaml
  verify:
    method: subagent
    prompt: "Search for hardcoded timeout/threshold values in conversation-helper.sh and entity-helper.sh. Verify that at least one uses AI judgment (calls to ai-research or similar) instead of a fixed number."
  ```
- [ ] Tests pass, ShellCheck clean on all new scripts
  ```yaml
  verify:
    method: bash
    run: "shellcheck ~/.aidevops/agents/scripts/entity-helper.sh ~/.aidevops/agents/scripts/conversation-helper.sh"
  ```

## Context & Decisions

- **SQLite over Postgres**: Consistent with existing memory system philosophy — no external dependencies, portable, WAL mode handles concurrent access. Entity memory doesn't need the scale that would justify Postgres.
- **Same database, new tables**: Entity tables live in `memory.db` alongside existing learnings. This enables cross-queries ("what do I know about this entity AND this project?") without cross-database joins.
- **Immutable Layer 0**: Inspired by event sourcing. Raw interactions are the source of truth. All higher layers are derived and can be re-derived. This is non-negotiable — memories are precious.
- **Versioned profiles over mutable state**: Entity profiles use the same `supersedes_id` chain as the existing memory relation system. A profile entry is never updated in place — a new version is created that supersedes the old one. The full history is preserved.
- **AI judgment over thresholds**: Where the existing system uses `DEFAULT_MAX_AGE_DAYS=90` or `sessionIdleTimeout: 300`, the new system uses haiku-tier AI calls. A haiku call costs ~$0.001 and handles outliers that no threshold can. Per the Intelligence Over Determinism principle.
- **Privacy-first identity resolution**: Never auto-link entities across channels without confirmation. A SimpleX DM is private by design — the system must respect that.
- **Flat-file conversation dumps rejected**: The OpenClaw approach (20k token raw dumps) doesn't scale. Structured summaries with source references at ~2k tokens recover 80% of continuity at 10% of the cost, and the raw data is always available in Layer 0 if needed.

## Relevant Files

- `.agents/scripts/memory-helper.sh` — existing memory entry point, needs entity dimension
- `.agents/scripts/memory/_common.sh` — DB init, needs schema migration
- `.agents/scripts/memory/store.sh` — store function, needs entity-aware variant
- `.agents/scripts/memory/recall.sh` — recall function, needs entity-scoped queries
- `.agents/scripts/memory/maintenance.sh` — prune/dedup, candidates for intelligent upgrades
- `.agents/services/communications/matrix-bot.md` — current per-room session model
- `.agents/services/communications/simplex.md` — bot framework integration point
- `.agents/scripts/mail-helper.sh` — inter-agent mailbox, transport adapters
- `.agents/memory/README.md` — memory system docs, needs entity section
- `todo/tasks/prd-memory-auto-capture.md` — related PRD for auto-capture

## Dependencies

- **Blocked by:** Nothing — this extends existing infrastructure
- **Blocks:** Multi-channel agent deployment (Matrix/SimpleX bots with relationship continuity)
- **External:** None — uses existing SQLite, existing AI research tool for judgment calls

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 2h | Review matrix-bot session model, memory schema, mail transport |
| t1363.1 Schema + entity-helper.sh | 6h | Core tables, CRUD, identity resolution, privacy filtering |
| t1363.2 conversation-helper.sh | 4h | Conversation lifecycle, context loading, intelligent idle detection |
| t1363.3 Memory system integration | 3h | Add entity dimension to memory-helper.sh, entity-scoped recall |
| t1363.4 Self-evolution loop | 4h | Gap detection, pattern scanning, TODO creation with evidence |
| t1363.5 Matrix bot integration | 3h | Replace per-room sessions with Layer 0/1, entity resolution |
| t1363.6 Intelligent threshold replacement | 2h | Replace hardcoded timeouts/ages with AI judgment |
| t1363.7 Architecture doc + tests | 3h | reference/entity-memory-architecture.md, ShellCheck, integration tests |
| **Total** | **27h** | |
