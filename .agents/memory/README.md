---
description: Memory template directory documentation
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Memory System

Cross-session memory using SQLite FTS5. **Requires**: `sqlite3` CLI.

```bash
sudo apt install sqlite3   # Ubuntu/Debian
brew install sqlite3       # macOS (usually pre-installed)
```

**Motto**: "Compound, then clear" — sessions build on each other.

**Architecture Decision: SQLite FTS5 over PostgreSQL** — no external server, no connection management, FTS5 provides fast full-text search out of the box.

## Entity Memory System

Tracks relationships with people, agents, and services across communication channels. Enables relationship continuity across session resets and context compaction.

**Architecture:** Three-layer design sharing `memory.db`. Full details: `reference/entity-memory-architecture.md`.

| Layer | Purpose | Script | Tables |
|-------|---------|--------|--------|
| Layer 0 | Raw interaction log (immutable, append-only) | `entity-helper.sh` | `interactions`, `interactions_fts` |
| Layer 1 | Per-conversation context (tactical summaries) | `conversation-helper.sh` | `conversations`, `conversation_summaries` |
| Layer 2 | Entity relationship model (strategic profiles) | `entity-helper.sh` | `entities`, `entity_channels`, `entity_profiles`, `capability_gaps` |
| Loop | Self-evolution (gap detection → TODO → upgrade) | `self-evolution-helper.sh` | `capability_gaps`, `gap_evidence` |

**Key concepts:** Entities are people/agents/services. Cross-channel identity links Matrix/SimpleX/email/CLI to the same entity (confidence: confirmed/suggested/inferred). Profiles are versioned via `supersedes_id` chain — never updated in place. Layer 0 is append-only; all other layers derived from it.

```bash
entity-helper.sh create --name "Marcus" --type person --channel matrix --channel-id "@marcus:server.com"
entity-helper.sh link ent_xxx --channel email --channel-id "marcus@example.com" --verified
entity-helper.sh log-interaction ent_xxx --channel matrix --content "How's the deployment going?"
conversation-helper.sh create --entity ent_xxx --channel matrix --channel-id "!room:server" --topic "Deployment"
conversation-helper.sh context conv_xxx --recent-messages 10
memory-helper.sh store --content "Prefers concise responses" --entity ent_xxx --type USER_PREFERENCE
memory-helper.sh recall --query "preferences" --entity ent_xxx
self-evolution-helper.sh pulse-scan --auto-todo-threshold 3
```

## Slash Commands

| Command | Purpose |
|---------|---------|
| `/remember {content}` | Store a memory with AI-assisted categorization |
| `/recall {query}` | Search memories by keyword |
| `/recall --recent` | Show 10 most recent memories |
| `/recall --auto-only` | Search only auto-captured memories |
| `/recall --stats` | Show memory statistics |
| `/memory-log` | Show recent auto-captured memories |

See `scripts/commands/remember.md` and `scripts/commands/recall.md` for full documentation.

## Memory Types

| Type | Use For |
|------|---------|
| `WORKING_SOLUTION` | Fixes that worked |
| `FAILED_APPROACH` | What didn't work (avoid repeating) |
| `CODEBASE_PATTERN` | Project conventions |
| `USER_PREFERENCE` | Developer preferences |
| `TOOL_CONFIG` | Tool setup notes |
| `DECISION` | General project decisions |
| `CONTEXT` | Background info |
| `ARCHITECTURAL_DECISION` | System-level architecture choices and trade-offs |
| `ERROR_FIX` | Bug fixes and patches |
| `OPEN_THREAD` | Unresolved questions or follow-ups |
| `SUCCESS_PATTERN` | Approaches that consistently work for task types |
| `FAILURE_PATTERN` | Approaches that consistently fail for task types |

## Auto-Recall

Surfaces at: interactive session start (last 5, via `conversation-starter.md`), session resume, and runner dispatch (recent + task-specific). Silent if no memories found; namespace-isolated for runners.

## Auto-Capture

Agents store memories automatically via `--auto` flag. Works with Claude Code, OpenCode, Cursor, Windsurf, or any AI tool that reads AGENTS.md. Privacy filters strip `<private>...</private>` blocks and reject secret patterns (API keys, tokens).

```bash
memory-helper.sh recall "query" --auto-only    # Auto-captured only
memory-helper.sh recall "query" --manual-only  # Manually stored only
memory-helper.sh log                           # Recent auto-captures
```

## Relation Types

| Relation | Use For | Example |
|----------|---------|---------|
| `updates` | New info supersedes old (state mutation) | "Favorite color is now green" updates "...is blue" |
| `extends` | Adds detail without contradiction | Adding job title to existing employment memory |
| `derives` | Second-order inference from combining | Inferring "works remotely" from location + job info |

## Dual Timestamps

| Timestamp | Purpose |
|-----------|---------|
| `created_at` | When the memory was stored in the database |
| `event_date` | When the event described actually occurred |

## Deduplication

On store: checks exact duplicates (identical content + type) and near-duplicates (normalized case/punctuation/whitespace). Increments access count on match instead of creating a new entry.

```bash
memory-helper.sh dedup --dry-run   # Preview
memory-helper.sh dedup             # Remove all duplicates (keeps oldest, merges tags)
memory-helper.sh dedup --exact-only
```

## Auto-Pruning

Runs on every `store` call (at most once per 24 hours). Removes entries older than 90 days that have never been accessed; frequently accessed memories are preserved regardless of age.

```bash
memory-helper.sh prune --older-than-days 60 --dry-run
memory-helper.sh prune --older-than-days 60
memory-helper.sh prune --older-than-days 180 --include-accessed
```

## Semantic Search (Opt-in)

```bash
memory-embeddings-helper.sh setup --provider local    # ~90MB download, no API key
memory-embeddings-helper.sh setup --provider openai   # Requires API key
memory-embeddings-helper.sh index                     # Index existing memories
memory-helper.sh recall "optimize database queries" --semantic
memory-helper.sh recall "authentication patterns" --hybrid  # FTS5 + semantic (RRF)
memory-embeddings-helper.sh status
```

| Provider | Model | Dimensions | Requirements |
|----------|-------|-----------|--------------|
| `local` | all-MiniLM-L6-v2 | 384 | Python 3.9+, sentence-transformers (~90MB) |
| `openai` | text-embedding-3-small | 1536 | Python 3.9+, numpy, OpenAI API key |

| Mode | Flag | Description |
|------|------|-------------|
| Keyword (default) | (none) | FTS5 BM25 full-text search |
| Semantic | `--semantic` | Vector similarity search |
| Hybrid | `--hybrid` | Combines keyword + semantic using Reciprocal Rank Fusion (RRF) |

Hybrid search recommended for natural language queries. New memories are auto-indexed once embeddings are configured.

## Retrieval Feedback Loop

Inspired by [Ori Mnemos](https://github.com/aayoawoyemi/Ori-Mnemos) Q-value system. Tracks whether recalled memories led to downstream actions — proven-useful memories rank higher in future recalls.

| Signal | Reward | When |
|--------|--------|------|
| `cited` | +1.0 | Referenced in new content |
| `led_to_new` | +0.6 | New memory created after retrieval |
| `edited` | +0.5 | Memory edited after retrieval |
| `reused` | +0.4 | Recalled across different queries |
| `dead_end` | -0.15 (floor: -1.0) | Retrieved but not used |

```bash
memory-helper.sh feedback mem_xxx --signal cited
memory-helper.sh feedback mem_xxx --signal dead_end
memory-helper.sh feedback mem_xxx --value 0.8   # Custom reward
```

**Ranking:** FTS5 blended score = `bm25(learnings) - (usefulness_score * 0.3)`. Hybrid (RRF): usefulness added as third signal. Call `feedback` after tasks where recalled memories contributed; pulse supervisor can batch-record from PR merge outcomes.

## Pattern Tracking

Handled by the cross-session memory system and pulse supervisor outcome observation (Step 2a). The pulse observes success/failure patterns from GitHub PR state (merged vs closed-without-merge) and files improvement issues when patterns emerge.

```bash
/patterns refactor          # Suggest patterns for a task
/patterns report            # Full report
/patterns recommend bugfix  # Model recommendation
/route "fix auth bug"       # Model routing (includes pattern data)
```

> **Note**: `pattern-tracker-helper.sh` has been archived. Pattern data in `memory.db` remains accessible via the memory system.

## Memory Graduation

Graduate validated local memories into shared documentation (`confidence = "high"` OR `access_count >= 3`).

```bash
memory-graduate-helper.sh candidates    # See what's ready
memory-graduate-helper.sh graduate --dry-run
memory-graduate-helper.sh graduate      # Appends to .agents/aidevops/graduated-learnings.md
```

**Slash command**: `/graduate-memories` or `/graduate-memories --dry-run`

## Memory Audit Pulse

Phase 9 of the supervisor pulse cycle (self-throttled to once per 24 hours).

```bash
memory-audit-pulse.sh run --force
memory-audit-pulse.sh run --dry-run
memory-audit-pulse.sh status
```

**Phases**: Dedup → Prune → Graduate → Consolidate → Scan → Report

## Memory Consolidation

Haiku-tier LLM call (~$0.001/call) scans unconsolidated memories, discovers cross-cutting connections, and stores synthesized insights. Inspired by Google's [always-on-memory-agent](https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/agents/always-on-memory-agent). Insights stored in `memory_consolidations`; connections as `derives` relations in `learning_relations`. Gracefully skips if `ai-research-helper.sh` or API key unavailable.

```bash
memory-helper.sh insights           # Manual trigger
memory-helper.sh insights --dry-run # Preview
0 4 * * * ~/.aidevops/agents/scripts/memory-audit-pulse.sh run --quiet  # Daily cron
```

## Namespaces (Per-Runner Memory Isolation)

```bash
memory-helper.sh --namespace code-reviewer store --content "Prefer explicit error handling"
memory-helper.sh --namespace code-reviewer recall "error handling"
memory-helper.sh --namespace code-reviewer recall "error handling" --shared  # Also search global
memory-helper.sh namespaces  # List all namespaces
```

Namespace DBs: `memory/namespaces/<name>/memory.db`. Global DB: `memory/memory.db`.

## Storage Location

```text
~/.aidevops/.agent-workspace/memory/
├── memory.db           # Global SQLite database with FTS5
│   ├── learnings        # Project memories (FTS5)
│   ├── learning_access  # Access tracking + usefulness_score (retrieval feedback)
│   ├── learning_relations # Relational versioning
│   ├── entities         # Entity records (person/agent/service)
│   ├── entity_channels  # Cross-channel identity links
│   ├── interactions     # Raw interaction log (Layer 0, immutable)
│   ├── interactions_fts # Interaction search index (FTS5)
│   ├── conversations    # Conversation lifecycle state
│   ├── conversation_summaries # Versioned summaries (Layer 1)
│   ├── entity_profiles  # Versioned preferences (Layer 2)
│   ├── capability_gaps  # Self-evolution gap tracking
│   └── memory_consolidations # Cross-memory insights (t1413)
├── embeddings.db       # Optional: vector embeddings for semantic search
├── namespaces/         # Per-runner isolated memory
└── preferences/        # Optional: markdown preference files
```

## CLI Reference

```bash
# Store
memory-helper.sh store --type "WORKING_SOLUTION" --content "Fixed CORS with nginx headers" --tags "cors,nginx"
memory-helper.sh store --content "Deployed v2.0" --event-date "2024-01-15T10:00:00Z"
memory-helper.sh store --content "New info" --supersedes mem_xxx --relation updates
memory-helper.sh store --content "Additional context" --supersedes mem_xxx --relation extends

# Recall
memory-helper.sh recall "cors"
memory-helper.sh recall --recent
memory-helper.sh recall "query" --type WORKING_SOLUTION --project myapp --limit 20

# Feedback
memory-helper.sh feedback mem_xxx --signal cited
memory-helper.sh feedback mem_xxx --signal dead_end
memory-helper.sh feedback mem_xxx --value 0.8

# Version history
memory-helper.sh history mem_xxx   # Show ancestors and descendants
memory-helper.sh latest mem_xxx    # Find latest version in chain

# Maintenance
memory-helper.sh stats
memory-helper.sh validate
memory-helper.sh dedup --dry-run && memory-helper.sh dedup
memory-helper.sh prune --dry-run && memory-helper.sh prune

# Export
memory-helper.sh export --format json
memory-helper.sh export --format toon

# Graduation
memory-graduate-helper.sh candidates
memory-graduate-helper.sh graduate --dry-run
memory-graduate-helper.sh graduate

# Namespaces
memory-helper.sh --namespace my-runner store --content "Runner-specific learning"
memory-helper.sh --namespace my-runner recall "query" --shared
memory-helper.sh namespaces
```

## Developer Preferences

Structured preference files complement the SQLite memory system:

```text
~/.aidevops/.agent-workspace/memory/preferences/
├── coding-style.md      # Indentation, line length, quote style, language-specific
├── documentation.md     # Comment density, JSDoc/PHPDoc, README format
├── workflow.md          # Git commit style, branch naming, testing, CI/CD
├── tools.md             # Editors, shell, Node/Python/package managers
└── project-specific/
    └── {project}.md     # Project-specific conventions and release process
```

Check `preferences/` before starting work; update when feedback is given; check project-specific files when switching projects.

## Security

- Never store credentials or API keys — use configuration references; keep secrets in `~/.config/aidevops/credentials.sh`
- No PII in shareable templates; regular cleanup of outdated information
- **This directory is version controlled** — keep it clean; use `~/.aidevops/.agent-workspace/memory/` for all actual operations
