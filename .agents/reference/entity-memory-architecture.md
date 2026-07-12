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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Entity Memory Architecture

**Plan:** p035 | **Tasks:** t1363.1–t1363.7 | **Database:** `memory.db`

## Purpose

Cross-channel relationship continuity for agents on Matrix, SimpleX, email, CLI, and similar channels. Core loop: interaction patterns → gap detection → auto TODO → system upgrade. Model evolves from observed user needs, not fixed assumptions.

## Core Decisions

| Decision | Why |
|----------|-----|
| Same `memory.db`, canonical observations | Enables cross-queries without cross-DB joins and gives every derived fact provenance |
| Three layers, not two | Layer 0 raw data is primary; summaries and profiles are derived |
| Versioned profiles via `supersedes_id` | Never update in place; mirrors `learning_relations` |
| Identity resolution requires confirmation | Never auto-link across channels |
| AI judgment for thresholds | Haiku-tier (~$0.001/call) handles outliers better than fixed thresholds |
| Structured summaries over flat dumps | ~2k tokens recovers ~80% continuity at ~10% of raw-dump cost |

## Layer Model

| Layer | Role | Tables | Script |
|-------|------|--------|--------|
| **Self-evolution loop** | Gap → TODO → upgrade | — | `self-evolution-helper.sh` |
| **2: Entity model** | Cross-channel identity, versioned profiles, capability gaps | entities, entity_channels, entity_profiles, capability_gaps, gap_evidence | `entity-helper.sh` |
| **1: Conversation context** | Active threads, immutable summaries, tone profile, pending actions | conversations, conversation_summaries | `conversation-helper.sh` |
| **0: Raw interaction log** | Immutable source of truth; FTS5 indexed; privacy-filtered on write | interactions, interactions_fts | `entity-helper.sh log-interaction` |

**Immutability:** Layer 0 and canonical `observations`/`observation_sources` are INSERT-only (except privacy deletion). Layers 1-2 use `supersedes_id` chains that project to `observation_relations`; new rows supersede old, never edit in place. Deterministic source IDs prevent replay from inflating evidence. Current record = row whose `id` is not referenced by another row's `supersedes_id`. Preserves full audit trail; avoids concurrent-write conflicts.

## Database Schema

All tables live in `~/.aidevops/.agent-workspace/memory/memory.db`. `observations` is canonical, `observation_sources` holds evidence/provenance, `observation_relations` holds truth and version transitions, and `observation_outcomes` holds usefulness/results. `learnings` remains the compatible FTS retrieval projection.

### Layer 0: `interactions` + `interactions_fts`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | `int_YYYYMMDDHHMMSS_hex` |
| `entity_id` | TEXT NOT NULL | FK → entities.id |
| `channel` | TEXT NOT NULL | `matrix\|simplex\|email\|cli\|slack\|discord\|telegram\|irc\|web` |
| `channel_id` | TEXT | Channel-specific room/contact |
| `conversation_id` | TEXT | FK → conversations.id |
| `direction` | TEXT | `inbound\|outbound\|system` |
| `content` | TEXT NOT NULL | Privacy-filtered |
| `metadata` | TEXT | JSON |
| `created_at` | TEXT | ISO 8601 UTC |

`interactions_fts` is an FTS5 mirror of `content` using the porter unicode61 tokenizer.

### Layer 1: `conversations` + `conversation_summaries`

| Table | Fields |
|-------|--------|
| **`conversations`** | `id` (conv_…), `entity_id`, `channel`, `channel_id`, `topic`, `summary` (denormalised latest), `status` (active\|idle\|closed), `interaction_count`, `first/last_interaction_at`, `created/updated_at` |
| **`conversation_summaries`** | `id` (sum_…), `conversation_id`, `summary`, `source_range_start/end` (interaction IDs covered), `source_interaction_count`, `tone_profile` (JSON: formality/technical_level/sentiment/pace), `pending_actions` (JSON array), `supersedes_id`, `created_at` |

### Layer 2: `entities`, `entity_channels`, `entity_profiles`, `capability_gaps`, `gap_evidence`

| Table | Fields |
|-------|--------|
| **`entities`** | `id` (ent_…), `name`, `type` (person\|agent\|service), `display_name`, `aliases`, `notes`, `created/updated_at` |
| **`entity_channels`** | PK `(channel, channel_id)` → `entity_id`, `display_name`, `confidence` (confirmed\|suggested\|inferred), `verified_at`, `created_at` |
| **`entity_profiles`** | `id` (prof_…), `entity_id`, `profile_key` (for example `communication_style`), `profile_value`, `evidence`, `confidence` (high\|medium\|low), `supersedes_id`, `created_at` |
| **`capability_gaps`** | `id` (gap_…), `entity_id`, `description`, `evidence`, `frequency`, `status` (detected\|todo_created\|resolved\|wont_fix), `todo_ref` (for example `t1400 GH#2600`), `created/updated_at` |
| **`gap_evidence`** | PK `(gap_id, interaction_id)`, `relevance` (primary\|supporting), `added_at` |

## Script Responsibilities

| Script | Layer | Responsibility |
|--------|-------|----------------|
| `entity-helper.sh` | 0 + 2 | Entity CRUD, channel linking, identity resolution, interaction logging, profile management, context loading |
| `conversation-helper.sh` | 1 | Conversation lifecycle, summary + recent-message context loading, AI-judged idle detection, immutable summary generation |
| `self-evolution-helper.sh` | Loop | AI-judged pattern scanning, gap detection, TODO creation via `claim-task-id.sh`, gap lifecycle, pulse integration |
| `memory-helper.sh` | — | Existing project-scoped memory with optional `--entity` linkage |

## Identity Resolution

1. **Suggest, don't assume.** `entity-helper.sh suggest` may propose matches; linking requires `entity-helper.sh link` or `verify`.
2. **Confidence levels:** `confirmed` (user verified), `suggested` (name or pattern match), `inferred` (display-name match).
3. **Primary key on `(channel, channel_id)`** — each channel identity maps to exactly one entity.

## Self-Evolution Loop

Flow: Layer 0 interactions → AI pattern detection (haiku, ~$0.001/call) → deduped gap identification with frequency tracking → TODO creation with interaction-ID evidence → normal task lifecycle (dispatch → PR → merge) → updated Layer 2 model.

Gap lifecycle: `detected` → `todo_created` → `resolved` | `wont_fix`. Auto-TODO creation starts at frequency ≥ 3 (configurable).

## Intelligent Threshold Replacement

| Old (deterministic) | New (intelligent) | Script |
|---------------------|-------------------|--------|
| `sessionIdleTimeout: 300` | AI judges whether a conversation has naturally paused | `conversation-helper.sh idle-check` |
| `DEFAULT_MAX_AGE_DAYS=90` | AI judges relevance to active entity relationships | `memory-helper.sh` (future) |
| Exact-string dedup | Semantic similarity via embeddings | `memory-helper.sh dedup` |
| Fixed compaction at token limit | AI judges what is worth preserving per entity | `conversation-helper.sh summarise` |

## Integration

```bash
# Cross-queries
memory-helper.sh store --content "Prefers concise responses" --entity ent_xxx --type USER_PREFERENCE
memory-helper.sh recall --query "deployment" --entity ent_xxx --project ~/Git/myproject

# Channel bots (Matrix, SimpleX)
conversation-helper.sh context conv_xxx --recent-messages 10
entity-helper.sh log-interaction ent_xxx --channel matrix --content "msg" --conversation-id conv_xxx

# Supervisor pulse (Step 3.5)
self-evolution-helper.sh pulse-scan --auto-todo-threshold 3 --repo-path ~/Git/aidevops
```

## Privacy Model

- **Write:** `<private>...</private>` stripped; secret patterns (API keys, tokens) rejected
- **Read:** `--privacy-filter` redacts emails, IPs, API keys
- **Channel isolation:** `--channel matrix` scopes context loading
- **Deletion:** Entity deletion cascades to all related data

## File Locations

```text
~/.aidevops/.agent-workspace/memory/
├── memory.db                          # Shared SQLite (all tables)
├── embeddings.db                      # Optional: vector embeddings
├── namespaces/<runner>/memory.db      # Per-runner isolation
└── preferences/                       # Optional: markdown preference files

.agents/scripts/
├── entity-helper.sh
├── conversation-helper.sh
├── self-evolution-helper.sh
├── memory-helper.sh
└── memory/                            # Modules: _common, store, recall, maintenance

tests/
├── test-entity-helper.sh
├── test-conversation-helper.sh
├── test-self-evolution-helper.sh
└── test-entity-memory-integration.sh
```
