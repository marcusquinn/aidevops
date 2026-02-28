---
description: Entity memory system architecture — three-layer design for cross-channel relationship continuity and self-evolution
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: false
---

# Entity Memory Architecture

**Plan:** p035 | **Tasks:** t1363.1–t1363.7 | **Database:** `memory.db` (shared with existing memory system)

## Purpose

Give aidevops multi-channel agents (Matrix, SimpleX, email, CLI) the ability to maintain relationship continuity with individuals across all channels — and self-evolve capabilities based on observed interaction patterns.

**The differentiator:** entity interaction patterns → capability gap detection → automatic TODO creation → system upgrade → better service. No chatbot platform does this. Everyone does conversation memory. Nobody does "the system upgrades itself based on what users actually need."

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Same SQLite database (`memory.db`), new tables | Enables cross-queries between entity and project memories without cross-DB joins |
| Three layers, not two | Layer 0 (immutable raw log) is the critical addition — summaries and profiles are derived, not primary |
| Versioned entity profiles via `supersedes_id` | Profiles are never updated in place — existing Supermemory pattern from `learning_relations` |
| Identity resolution requires confirmation | Never auto-link entities across channels. Suggest, don't assume |
| AI judgment for thresholds | Haiku-tier calls (~$0.001) handle outliers that no fixed threshold can. Per Intelligence Over Determinism principle |
| Flat-file conversation dumps rejected | Structured summaries with source references at ~2k tokens recover 80% of continuity at 10% of the cost; raw data always available in Layer 0 |

## Three-Layer Architecture

```text
┌─────────────────────────────────────────────────────────────────────┐
│                    SELF-EVOLUTION LOOP                               │
│  Interactions → Pattern detection → Gap identification              │
│  → TODO creation → System upgrade → Better service                  │
│  (self-evolution-helper.sh)                                         │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
┌──────────────────────────┴──────────────────────────────────────────┐
│ LAYER 2: ENTITY RELATIONSHIP MODEL (strategic)                      │
│ Tables: entities, entity_channels, entity_profiles, capability_gaps │
│ Script: entity-helper.sh                                            │
│                                                                     │
│ • Identity: cross-channel linking (Matrix + SimpleX + email = same  │
│   person), confidence levels (confirmed/suggested/inferred)         │
│ • Profiles: versioned preferences, needs, expectations — with      │
│   evidence and supersedes_id chain                                  │
│ • Gaps: capability deficiencies detected from interaction patterns, │
│   frequency tracking, automatic TODO creation                       │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
┌──────────────────────────┴──────────────────────────────────────────┐
│ LAYER 1: PER-CONVERSATION CONTEXT (tactical)                        │
│ Tables: conversations, conversation_summaries                       │
│ Script: conversation-helper.sh                                      │
│                                                                     │
│ • Active threads per entity+channel                                 │
│ • Immutable summaries with source range references                  │
│ • Tone/style profile, pending actions                               │
│ • AI-judged idle detection (not fixed timeout)                      │
│ • Model-agnostic context loading for channel integrations           │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
┌──────────────────────────┴──────────────────────────────────────────┐
│ LAYER 0: RAW INTERACTION LOG (immutable, append-only)               │
│ Tables: interactions, interactions_fts                               │
│ Script: entity-helper.sh (log-interaction command)                   │
│                                                                     │
│ • Every message across all channels                                 │
│ • Source of truth — all other layers derived from this              │
│ • Privacy-filtered on write (secrets rejected, <private> stripped)  │
│ • FTS5 full-text search index                                       │
│ • Retention: indefinite (user can request privacy deletion)         │
└─────────────────────────────────────────────────────────────────────┘
```

## Database Schema

All tables live in `~/.aidevops/.agent-workspace/memory/memory.db` alongside the existing `learnings`, `learning_access`, and `learning_relations` tables.

### Layer 0: Interactions (immutable)

```sql
CREATE TABLE interactions (
    id TEXT PRIMARY KEY,              -- int_YYYYMMDDHHMMSS_hex
    entity_id TEXT NOT NULL,          -- FK → entities.id
    channel TEXT NOT NULL,            -- matrix|simplex|email|cli|slack|discord|telegram|irc|web
    channel_id TEXT DEFAULT NULL,     -- channel-specific room/contact ID
    conversation_id TEXT DEFAULT NULL, -- FK → conversations.id
    direction TEXT NOT NULL DEFAULT 'inbound',  -- inbound|outbound|system
    content TEXT NOT NULL,            -- message content (privacy-filtered)
    metadata TEXT DEFAULT '{}',       -- JSON: extra context
    created_at TEXT DEFAULT (ISO 8601 UTC)
);

-- FTS5 index for full-text search across all interactions
CREATE VIRTUAL TABLE interactions_fts USING fts5(
    id UNINDEXED, entity_id UNINDEXED, content,
    channel UNINDEXED, created_at UNINDEXED,
    tokenize='porter unicode61'
);
```

**Immutability constraint:** Interactions are INSERT-only. No UPDATE or DELETE operations are permitted on this table (except privacy deletion requests). This is enforced by the `log-interaction` command in `entity-helper.sh` — there is no `update-interaction` or `delete-interaction` command. The FTS index mirrors the interactions table.

### Layer 1: Conversations

```sql
CREATE TABLE conversations (
    id TEXT PRIMARY KEY,              -- conv_YYYYMMDDHHMMSS_hex
    entity_id TEXT NOT NULL,          -- FK → entities.id
    channel TEXT NOT NULL,
    channel_id TEXT DEFAULT NULL,
    topic TEXT DEFAULT '',
    summary TEXT DEFAULT '',          -- latest summary (denormalised)
    status TEXT DEFAULT 'active',     -- active|idle|closed
    interaction_count INTEGER DEFAULT 0,
    first_interaction_at TEXT DEFAULT NULL,
    last_interaction_at TEXT DEFAULT NULL,
    created_at TEXT, updated_at TEXT
);

-- Immutable, versioned summaries
CREATE TABLE conversation_summaries (
    id TEXT PRIMARY KEY,              -- sum_YYYYMMDDHHMMSS_hex
    conversation_id TEXT NOT NULL,    -- FK → conversations.id
    summary TEXT NOT NULL,
    source_range_start TEXT NOT NULL, -- first interaction ID covered
    source_range_end TEXT NOT NULL,   -- last interaction ID covered
    source_interaction_count INTEGER DEFAULT 0,
    tone_profile TEXT DEFAULT '{}',   -- JSON: formality, technical_level, sentiment, pace
    pending_actions TEXT DEFAULT '[]', -- JSON array of follow-ups
    supersedes_id TEXT DEFAULT NULL,  -- FK → conversation_summaries.id
    created_at TEXT
);
```

**Summary immutability:** Summaries are never edited. New summaries supersede old ones via the `supersedes_id` chain. The "current" summary is the one whose `id` does not appear as any other summary's `supersedes_id`.

### Layer 2: Entities and Profiles

```sql
CREATE TABLE entities (
    id TEXT PRIMARY KEY,              -- ent_YYYYMMDDHHMMSS_hex
    name TEXT NOT NULL,
    type TEXT NOT NULL,               -- person|agent|service
    display_name TEXT DEFAULT NULL,
    aliases TEXT DEFAULT '',
    notes TEXT DEFAULT '',
    created_at TEXT, updated_at TEXT
);

-- Cross-channel identity linking
CREATE TABLE entity_channels (
    entity_id TEXT NOT NULL,          -- FK → entities.id
    channel TEXT NOT NULL,
    channel_id TEXT NOT NULL,         -- channel-specific identifier
    display_name TEXT DEFAULT NULL,
    confidence TEXT DEFAULT 'suggested', -- confirmed|suggested|inferred
    verified_at TEXT DEFAULT NULL,
    created_at TEXT,
    PRIMARY KEY (channel, channel_id)
);

-- Versioned entity profiles (never updated in place)
CREATE TABLE entity_profiles (
    id TEXT PRIMARY KEY,              -- prof_YYYYMMDDHHMMSS_hex
    entity_id TEXT NOT NULL,
    profile_key TEXT NOT NULL,        -- e.g., "communication_style", "technical_level"
    profile_value TEXT NOT NULL,
    evidence TEXT DEFAULT '',         -- what interactions support this
    confidence TEXT DEFAULT 'medium', -- high|medium|low
    supersedes_id TEXT DEFAULT NULL,  -- FK → entity_profiles.id
    created_at TEXT
);

-- Capability gaps detected from interaction patterns
CREATE TABLE capability_gaps (
    id TEXT PRIMARY KEY,              -- gap_YYYYMMDDHHMMSS_hex
    entity_id TEXT DEFAULT NULL,
    description TEXT NOT NULL,
    evidence TEXT DEFAULT '',
    frequency INTEGER DEFAULT 1,
    status TEXT DEFAULT 'detected',   -- detected|todo_created|resolved|wont_fix
    todo_ref TEXT DEFAULT NULL,       -- e.g., "t1400 (GH#2600)"
    created_at TEXT, updated_at TEXT
);

-- Evidence trail: gap → interaction IDs → raw messages
CREATE TABLE gap_evidence (
    gap_id TEXT NOT NULL,
    interaction_id TEXT NOT NULL,
    relevance TEXT DEFAULT 'primary',
    added_at TEXT,
    PRIMARY KEY (gap_id, interaction_id)
);
```

**Profile immutability:** Entity profiles use the same `supersedes_id` pattern as the existing `learning_relations` table. When a profile entry is updated, a new row is created with `supersedes_id` pointing to the previous version. The "current" value for a key is the row whose `id` does not appear as any other profile's `supersedes_id`.

## Script Responsibilities

| Script | Layer | Responsibility |
|--------|-------|----------------|
| `entity-helper.sh` | 0 + 2 | Entity CRUD, channel linking, identity resolution, interaction logging (Layer 0), profile management, context loading |
| `conversation-helper.sh` | 1 | Conversation lifecycle (create/resume/archive/close), context loading (Layer 1 summary + recent Layer 0 messages), AI-judged idle detection, immutable summary generation, tone profile extraction |
| `self-evolution-helper.sh` | Loop | Pattern scanning (AI-judged), gap detection and recording, TODO creation via `claim-task-id.sh`, gap lifecycle management, pulse integration |
| `memory-helper.sh` | — | Existing project-scoped memory (learnings). Entity-linked via `--entity` flag for cross-queries |

## Immutability Constraints

The system enforces immutability at three levels:

1. **Layer 0 (interactions):** Append-only. No update/delete commands exist. Privacy deletion is the only exception (user-requested data removal).

2. **Layer 1 (conversation_summaries):** Insert-only with supersedes chain. Summaries are never edited — new summaries reference the old via `supersedes_id`.

3. **Layer 2 (entity_profiles):** Insert-only with supersedes chain. Profile values are never updated in place — new versions supersede old ones.

These constraints ensure:
- Full audit trail — every state change is traceable
- No data loss — previous versions are always accessible
- Conflict-free — concurrent writers can't corrupt existing data
- Debuggable — if a profile or summary is wrong, the evidence chain shows why

## Identity Resolution

Cross-channel identity linking follows a conservative approach:

1. **Suggest, don't assume.** When a new channel identity appears, `entity-helper.sh suggest` looks for potential matches but never auto-links.

2. **Confidence levels:**
   - `confirmed` — User explicitly verified the link
   - `suggested` — System proposed based on name/pattern similarity
   - `inferred` — Pattern match (e.g., same display name across channels)

3. **Primary key on (channel, channel_id):** Each channel identity maps to exactly one entity. Relinking requires explicit unlink + relink.

4. **No auto-merge:** Even if two entities appear to be the same person, they remain separate until a human confirms the link via `entity-helper.sh link` or `entity-helper.sh verify`.

## Self-Evolution Loop

```text
Entity interactions (Layer 0)
  → Pattern detection (AI judgment via haiku, ~$0.001/call)
  → Capability gap identification (deduplication, frequency tracking)
  → TODO creation with evidence trail (interaction IDs)
  → System upgrade (normal aidevops task lifecycle: dispatch → PR → merge)
  → Better service to entity
  → Updated entity model (Layer 2)
  → Cycle continues
```

**Gap lifecycle:** `detected` → `todo_created` → `resolved` | `wont_fix`

**Auto-TODO threshold:** When a gap's frequency reaches 3 (configurable), `pulse-scan` automatically creates a TODO task via `claim-task-id.sh`. The issue body includes the full evidence trail (interaction IDs and message snippets).

## Intelligent Threshold Replacement

The entity memory system replaces several hardcoded thresholds with AI-judged decisions:

| Old (deterministic) | New (intelligent) | Script |
|---------------------|-------------------|--------|
| `sessionIdleTimeout: 300` | AI judges "has this conversation naturally paused?" with heuristic fallback | `conversation-helper.sh idle-check` |
| `DEFAULT_MAX_AGE_DAYS=90` | AI judges "is this memory still relevant to active entity relationships?" | `memory-helper.sh` (future) |
| Exact-string dedup | Semantic similarity via existing embeddings | `memory-helper.sh dedup` |
| Fixed compaction at token limit | AI judges "what's worth preserving for this entity?" | `conversation-helper.sh summarise` |

## Integration Points

### Existing Memory System

The entity system shares `memory.db` with the existing `learnings` table. Cross-queries are possible:

```bash
# Store a memory linked to an entity
memory-helper.sh store --content "Prefers concise responses" --entity ent_xxx --type USER_PREFERENCE

# Recall memories for an entity
memory-helper.sh recall --query "preferences" --entity ent_xxx

# Cross-query: entity + project
memory-helper.sh recall --query "deployment" --entity ent_xxx --project ~/Git/myproject
```

### Channel Integrations

Channel bots (Matrix, SimpleX) use `conversation-helper.sh context` to load model-agnostic context before responding:

```bash
# Load context for a conversation (includes entity profile + summary + recent messages)
conversation-helper.sh context conv_xxx --recent-messages 10

# Log an interaction after responding
entity-helper.sh log-interaction ent_xxx --channel matrix --content "message" --conversation-id conv_xxx
```

### Supervisor Pulse

The self-evolution loop integrates with the supervisor pulse cycle:

```bash
# Run as part of pulse (Step 3.5)
self-evolution-helper.sh pulse-scan --auto-todo-threshold 3 --repo-path ~/Git/aidevops
```

## Privacy Model

- **On write:** `<private>...</private>` blocks stripped; content matching secret patterns (API keys, tokens) rejected
- **On read:** `--privacy-filter` flag redacts emails, IPs, and API keys in output
- **Channel isolation:** Context loading can be filtered by channel (`--channel matrix`)
- **Deletion:** Entity deletion cascades to all related data (channels, interactions, conversations, profiles, gaps)

## File Locations

```text
~/.aidevops/.agent-workspace/memory/
├── memory.db                    # Shared SQLite database (all tables)
├── embeddings.db                # Optional: vector embeddings
├── namespaces/                  # Per-runner isolated memory
│   └── <runner>/memory.db
└── preferences/                 # Optional: markdown preference files

Scripts:
├── .agents/scripts/entity-helper.sh          # Layer 0 + 2
├── .agents/scripts/conversation-helper.sh    # Layer 1
├── .agents/scripts/self-evolution-helper.sh  # Self-evolution loop
├── .agents/scripts/memory-helper.sh          # Existing memory system
└── .agents/scripts/memory/                   # Memory system modules
    ├── _common.sh
    ├── store.sh
    ├── recall.sh
    └── maintenance.sh

Tests:
├── tests/test-entity-helper.sh
├── tests/test-conversation-helper.sh
├── tests/test-self-evolution-helper.sh
└── tests/test-entity-memory-integration.sh   # Cross-layer integration tests
```

## What aidevops Already Had (Overlap)

- SQLite FTS5 memory with relational versioning (updates/extends/derives)
- Dual timestamps (created_at vs event_date)
- Memory namespaces (per-runner isolation)
- Semantic search via embeddings (opt-in)
- Matrix bot with per-room sessions and compaction
- SimpleX bot framework with WebSocket API
- Mail system with transport adapters (local/SimpleX/Matrix)
- Auto-capture with privacy filters
- Memory graduation (local → shared docs)

## What's Genuinely New

- Entity concept (person/agent/service with cross-channel identity)
- Per-conversation context that survives compaction and session resets
- Entity relationship model (inferred needs, expectations, capability gaps)
- Self-evolution loop (gap detection → TODO creation with evidence)
- Privacy-aware cross-channel context loading
- AI-judged thresholds replacing hardcoded values
- Immutable interaction log as source of truth
