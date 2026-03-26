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

**Plan:** p035 | **Tasks:** t1363.1–t1363.7 | **Database:** `memory.db`

## Purpose

Give multi-channel agents (Matrix, SimpleX, email, CLI) relationship continuity with individuals across channels, and self-evolve capabilities from observed interaction patterns.

**Differentiator:** interaction patterns → gap detection → auto TODO → system upgrade → better service. Everyone does conversation memory. Nobody does "the system upgrades itself based on what users actually need."

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Same `memory.db`, new tables | Cross-queries between entity and project memories without cross-DB joins |
| Three layers, not two | Layer 0 (immutable raw log) is primary — summaries/profiles are derived |
| Versioned profiles via `supersedes_id` | Never update in place — mirrors existing `learning_relations` pattern |
| Identity resolution requires confirmation | Never auto-link across channels. Suggest, don't assume |
| AI judgment for thresholds | Haiku-tier (~$0.001/call) handles outliers fixed thresholds can't |
| Structured summaries over flat dumps | ~2k tokens recovers 80% of continuity at 10% of cost; raw data in Layer 0 |

## Three-Layer Architecture

| Layer | Role | Tables | Script |
|-------|------|--------|--------|
| **Self-evolution loop** | Gap → TODO → upgrade | — | `self-evolution-helper.sh` |
| **2: Entity model** (strategic) | Cross-channel identity, versioned profiles, capability gaps | entities, entity_channels, entity_profiles, capability_gaps, gap_evidence | `entity-helper.sh` |
| **1: Conversation context** (tactical) | Active threads, immutable summaries, tone profile, pending actions | conversations, conversation_summaries | `conversation-helper.sh` |
| **0: Raw interaction log** (immutable) | Source of truth — all layers derived from this; FTS5 indexed; privacy-filtered on write | interactions, interactions_fts | `entity-helper.sh log-interaction` |

**Immutability:** Layer 0 is INSERT-only (no UPDATE/DELETE except privacy deletion). Layers 1–2 use `supersedes_id` chains — new rows supersede old, never edit in place. Current record = row whose `id` appears in no other row's `supersedes_id`. Guarantees full audit trail, no data loss, conflict-free concurrent writes.

## Database Schema

All tables in `~/.aidevops/.agent-workspace/memory/memory.db` alongside existing `learnings`, `learning_access`, `learning_relations`.

### Layer 0: `interactions` + `interactions_fts`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | `int_YYYYMMDDHHMMSS_hex` |
| `entity_id` | TEXT NOT NULL | FK → entities.id |
| `channel` | TEXT NOT NULL | `matrix\|simplex\|email\|cli\|slack\|discord\|telegram\|irc\|web` |
| `channel_id` | TEXT | channel-specific room/contact |
| `conversation_id` | TEXT | FK → conversations.id |
| `direction` | TEXT | `inbound\|outbound\|system` |
| `content` | TEXT NOT NULL | privacy-filtered |
| `metadata` | TEXT | JSON |
| `created_at` | TEXT | ISO 8601 UTC |

FTS5 virtual table `interactions_fts` mirrors content with porter unicode61 tokenizer.

### Layer 1: `conversations` + `conversation_summaries`

**conversations:** `id` (conv_…), `entity_id`, `channel`, `channel_id`, `topic`, `summary` (denormalised latest), `status` (active|idle|closed), `interaction_count`, `first/last_interaction_at`, `created/updated_at`

**conversation_summaries:** `id` (sum_…), `conversation_id`, `summary`, `source_range_start/end` (interaction IDs covered), `source_interaction_count`, `tone_profile` (JSON: formality/technical_level/sentiment/pace), `pending_actions` (JSON array), `supersedes_id`, `created_at`

### Layer 2: `entities`, `entity_channels`, `entity_profiles`, `capability_gaps`, `gap_evidence`

**entities:** `id` (ent_…), `name`, `type` (person|agent|service), `display_name`, `aliases`, `notes`, `created/updated_at`

**entity_channels:** PK `(channel, channel_id)` → `entity_id`, `display_name`, `confidence` (confirmed|suggested|inferred), `verified_at`, `created_at`

**entity_profiles:** `id` (prof_…), `entity_id`, `profile_key` (e.g. communication_style), `profile_value`, `evidence`, `confidence` (high|medium|low), `supersedes_id`, `created_at`

**capability_gaps:** `id` (gap_…), `entity_id`, `description`, `evidence`, `frequency`, `status` (detected|todo_created|resolved|wont_fix), `todo_ref` (e.g. t1400 GH#2600), `created/updated_at`

**gap_evidence:** PK `(gap_id, interaction_id)`, `relevance` (primary|supporting), `added_at`

## Script Responsibilities

| Script | Layer | Responsibility |
|--------|-------|----------------|
| `entity-helper.sh` | 0 + 2 | Entity CRUD, channel linking, identity resolution, interaction logging, profile management, context loading |
| `conversation-helper.sh` | 1 | Conversation lifecycle, context loading (summary + recent messages), AI-judged idle detection, immutable summary generation |
| `self-evolution-helper.sh` | Loop | Pattern scanning (AI-judged), gap detection, TODO creation via `claim-task-id.sh`, gap lifecycle, pulse integration |
| `memory-helper.sh` | — | Existing project-scoped memory; entity-linked via `--entity` flag |

## Identity Resolution

1. **Suggest, don't assume.** `entity-helper.sh suggest` proposes matches; never auto-links.
2. **Confidence levels:** `confirmed` (user verified) | `suggested` (name/pattern match) | `inferred` (display name match)
3. **Primary key on `(channel, channel_id)`** — each channel identity maps to exactly one entity.
4. **No auto-merge** — separate entities until human confirms via `entity-helper.sh link` or `verify`.

## Self-Evolution Loop

```text
Layer 0 interactions
  → AI pattern detection (haiku, ~$0.001/call)
  → Gap identification (dedup, frequency tracking)
  → TODO creation with evidence trail (interaction IDs)
  → Normal task lifecycle: dispatch → PR → merge
  → Updated entity model (Layer 2)
  → Cycle continues
```

**Gap lifecycle:** `detected` → `todo_created` → `resolved` | `wont_fix`

**Auto-TODO threshold:** frequency ≥ 3 (configurable) triggers `claim-task-id.sh` with full evidence trail.

## Intelligent Threshold Replacement

| Old (deterministic) | New (intelligent) | Script |
|---------------------|-------------------|--------|
| `sessionIdleTimeout: 300` | AI judges "has this conversation naturally paused?" | `conversation-helper.sh idle-check` |
| `DEFAULT_MAX_AGE_DAYS=90` | AI judges relevance to active entity relationships | `memory-helper.sh` (future) |
| Exact-string dedup | Semantic similarity via embeddings | `memory-helper.sh dedup` |
| Fixed compaction at token limit | AI judges what's worth preserving per entity | `conversation-helper.sh summarise` |

## Integration

### Memory system cross-queries

```bash
memory-helper.sh store --content "Prefers concise responses" --entity ent_xxx --type USER_PREFERENCE
memory-helper.sh recall --query "deployment" --entity ent_xxx --project ~/Git/myproject
```

### Channel bots (Matrix, SimpleX)

```bash
conversation-helper.sh context conv_xxx --recent-messages 10
entity-helper.sh log-interaction ent_xxx --channel matrix --content "msg" --conversation-id conv_xxx
```

### Supervisor pulse (Step 3.5)

```bash
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
├── entity-helper.sh                   # Layer 0 + 2
├── conversation-helper.sh             # Layer 1
├── self-evolution-helper.sh           # Self-evolution loop
├── memory-helper.sh                   # Existing memory system
└── memory/                            # Modules: _common, store, recall, maintenance

tests/
├── test-entity-helper.sh
├── test-conversation-helper.sh
├── test-self-evolution-helper.sh
└── test-entity-memory-integration.sh
```
