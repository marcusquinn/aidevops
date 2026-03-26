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

Cross-session memory for AI assistants using SQLite FTS5 for fast full-text search.

**Requires**: `sqlite3` CLI (includes FTS5 by default)

```bash
sudo apt install sqlite3   # Ubuntu/Debian
brew install sqlite3       # macOS (usually pre-installed)
sqlite3 --version          # Verify
```

**Motto**: "Compound, then clear" — sessions should build on each other.

**Architecture Decision: SQLite FTS5 over PostgreSQL** — chosen to minimize deployment complexity and eliminate external dependencies. No separate database server, no connection management, FTS5 provides fast full-text search out of the box.

## Entity Memory System

Extends beyond project-scoped learnings to track relationships with people, agents, and services across all communication channels. Enables relationship continuity that survives session resets and context compaction.

**Architecture:** Three-layer design sharing the same `memory.db`. Full architecture: `reference/entity-memory-architecture.md`.

| Layer | Purpose | Script | Tables |
|-------|---------|--------|--------|
| Layer 0 | Raw interaction log (immutable, append-only) | `entity-helper.sh` | `interactions`, `interactions_fts` |
| Layer 1 | Per-conversation context (tactical summaries) | `conversation-helper.sh` | `conversations`, `conversation_summaries` |
| Layer 2 | Entity relationship model (strategic profiles) | `entity-helper.sh` | `entities`, `entity_channels`, `entity_profiles`, `capability_gaps` |
| Loop | Self-evolution (gap detection → TODO → upgrade) | `self-evolution-helper.sh` | `capability_gaps`, `gap_evidence` |

**Key concepts:**
- **Entities** — people, agents, or services the system interacts with
- **Cross-channel identity** — link Matrix, SimpleX, email, CLI identities to the same entity (confidence: confirmed/suggested/inferred)
- **Versioned profiles** — entity preferences never updated in place; new versions supersede old via `supersedes_id` chain
- **Immutable interactions** — Layer 0 is append-only; all other layers derived from it
- **Self-evolution loop** — interaction patterns → capability gap detection → automatic TODO creation → system upgrade

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

## Quick Start

```bash
# Store a memory
~/.aidevops/agents/scripts/memory-helper.sh store --type "WORKING_SOLUTION" --content "Fixed CORS with nginx headers" --tags "cors,nginx"

# Store with event date (when it happened, not when stored)
~/.aidevops/agents/scripts/memory-helper.sh store --content "Deployed v2.0" --event-date "2024-01-15T10:00:00Z"

# Update an existing memory (creates version chain)
~/.aidevops/agents/scripts/memory-helper.sh store --content "Favorite color is now green" --supersedes mem_xxx --relation updates

# Recall memories
~/.aidevops/agents/scripts/memory-helper.sh recall "cors"
~/.aidevops/agents/scripts/memory-helper.sh recall --recent

# Maintenance
~/.aidevops/agents/scripts/memory-helper.sh stats
~/.aidevops/agents/scripts/memory-helper.sh dedup --dry-run && memory-helper.sh dedup
~/.aidevops/agents/scripts/memory-helper.sh validate
```

## Auto-Recall

Memories are automatically recalled at key entry points:

- **Interactive sessions**: Recent memories (last 5) surface via `conversation-starter.md`
- **Session resume**: After loading checkpoint, recent memories provide context
- **Runner dispatch**: Before task execution, runners recall recent + task-specific memories
- **Behavior**: Silent if no memories found; namespace-isolated for runners; formatted as markdown sections

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

## Auto-Capture

AI agents automatically store memories using the `--auto` flag when they detect significant events. Tool-agnostic — works with Claude Code, OpenCode, Cursor, Windsurf, or any AI tool that reads AGENTS.md.

**Privacy filters** (applied automatically on store):
- `<private>...</private>` blocks are stripped
- Content matching secret patterns (API keys, tokens) is rejected

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

**On store (automatic):** Checks for exact duplicates (identical content + type) and near-duplicates (same content after normalizing case/punctuation/whitespace). Increments access count on match instead of creating a new entry.

```bash
memory-helper.sh dedup --dry-run   # Preview
memory-helper.sh dedup             # Remove all duplicates (keeps oldest, merges tags)
memory-helper.sh dedup --exact-only
```

## Auto-Pruning

Runs opportunistically on every `store` call (at most once per 24 hours). Removes entries older than 90 days that have never been accessed. Frequently accessed memories are preserved regardless of age.

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

Hybrid search is recommended for natural language queries. New memories stored via `memory-helper.sh store` are automatically indexed once embeddings are configured.

## Retrieval Feedback Loop

Inspired by [Ori Mnemos](https://github.com/aayoawoyemi/Ori-Mnemos) Q-value system, simplified for operational use. Tracks whether recalled memories led to downstream actions. Memories that prove useful in practice rank higher in future recalls.

**How it works:** When a recalled memory leads to a useful outcome (cited in new content, edited, led to a new memory), the caller records positive feedback. This increments a `usefulness_score` in `learning_access`. Future FTS5 and hybrid searches blend BM25 relevance with usefulness_score, so proven-useful memories get a ranking boost.

```bash
# Record feedback: memory was cited in new content
memory-helper.sh feedback mem_xxx --signal cited

# Record feedback: memory was edited after retrieval
memory-helper.sh feedback mem_xxx --signal edited

# Record feedback: a new memory was created after retrieving this one
memory-helper.sh feedback mem_xxx --signal led_to_new

# Record feedback: same memory recalled across different queries
memory-helper.sh feedback mem_xxx --signal reused

# Record negative feedback: retrieved but not used
memory-helper.sh feedback mem_xxx --signal dead_end

# Custom reward value
memory-helper.sh feedback mem_xxx --value 0.8
```

**Signal types and rewards:**

| Signal | Reward | Trigger |
|--------|--------|---------|
| `cited` | +1.0 | Memory was referenced/linked in new content |
| `edited` | +0.5 | Memory was edited/updated after retrieval |
| `led_to_new` | +0.6 | A new memory was created after retrieving this one |
| `reused` | +0.4 | Same memory recalled across different queries in session |
| `dead_end` | -0.15 | Retrieved in top results but no follow-up action |

**Ranking integration:**

- **FTS5 search:** Blended score = `bm25(learnings) - (usefulness_score * 0.3)`. The 0.3 lambda weight promotes proven-useful results by 1-2 positions without overriding strong keyword relevance.
- **Hybrid search (RRF):** Usefulness score is added as a third signal in Reciprocal Rank Fusion, scaled to RRF magnitude.
- **Score floor:** -1.0 minimum prevents a few `dead_end` signals from permanently burying a memory.

**When to call feedback:** AI agents should call `feedback` after completing a task where recalled memories contributed to the outcome. The pulse supervisor can also batch-record feedback based on PR merge outcomes.

## Pattern Tracking

Pattern tracking is handled by the cross-session memory system and the pulse supervisor's outcome observation (Step 2a).

```bash
/patterns refactor          # Suggest patterns for a task
/patterns report            # Full report
/patterns recommend bugfix  # Model recommendation
/route "fix auth bug"       # Model routing (includes pattern data)
/remember "Structured debugging found root cause for bugfix t102.3 (sonnet, 120s)"
/recall "bugfix patterns"
```

The pulse supervisor observes success/failure patterns from GitHub PR state (merged vs closed-without-merge) and files improvement issues when patterns emerge.

> **Note**: `pattern-tracker-helper.sh` has been archived. Pattern data in `memory.db` remains accessible via the memory system.

## Memory Graduation (Sharing Learnings)

Graduate validated local memories into shared documentation so all framework users benefit. Memories qualify when they reach high confidence or are accessed frequently.

```bash
memory-graduate-helper.sh candidates    # See what's ready
memory-graduate-helper.sh graduate --dry-run
memory-graduate-helper.sh graduate      # Appends to .agents/aidevops/graduated-learnings.md
```

**Graduation criteria** (any of): `confidence = "high"` OR `access_count >= 3`.

**Slash command**: `/graduate-memories` or `/graduate-memories --dry-run`

## Memory Audit Pulse (Automated Hygiene)

Runs automatically as Phase 9 of the supervisor pulse cycle (self-throttled to once per 24 hours).

```bash
memory-audit-pulse.sh run --force
memory-audit-pulse.sh run --dry-run
memory-audit-pulse.sh status
```

**Phases**: Dedup → Prune → Graduate → Consolidate → Scan → Report

## Memory Consolidation (Cross-Memory Insight Generation)

Uses a cheap LLM call (haiku-tier, ~$0.001/call) to scan unconsolidated memories, discover cross-cutting connections, and store synthesized insights. Inspired by Google's [always-on-memory-agent](https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/agents/always-on-memory-agent).

```bash
memory-helper.sh insights           # Manual trigger
memory-helper.sh insights --dry-run # Preview
```

Insights stored in `memory_consolidations` table; connections stored as `derives` relations in `learning_relations`. Cost: ~$0.001-0.01 per audit pulse run. Gracefully skips if `ai-research-helper.sh` or API key unavailable.

```bash
# Daily at 4 AM (optional cron)
0 4 * * * ~/.aidevops/agents/scripts/memory-audit-pulse.sh run --quiet
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
memory-helper.sh store --type "TYPE" --content "content" --tags "tags" --project "project-name"
memory-helper.sh store --content "Fixed bug" --event-date "2024-01-15T10:00:00Z"
memory-helper.sh store --content "New info" --supersedes mem_xxx --relation updates
memory-helper.sh store --content "Additional context" --supersedes mem_xxx --relation extends

# Recall
memory-helper.sh recall "query" --type WORKING_SOLUTION --project myapp --limit 20
memory-helper.sh recall --recent 10

# Retrieval feedback (mark recalled memories as useful/not useful)
memory-helper.sh feedback mem_xxx --signal cited       # Memory was referenced in new content
memory-helper.sh feedback mem_xxx --signal dead_end    # Retrieved but not used
memory-helper.sh feedback mem_xxx --value 0.8          # Custom reward value

# Version history
memory-helper.sh history mem_xxx   # Show ancestors and descendants
memory-helper.sh latest mem_xxx    # Find latest version in chain

# Maintenance
memory-helper.sh validate
memory-helper.sh dedup --dry-run && memory-helper.sh dedup
memory-helper.sh prune --dry-run && memory-helper.sh prune

# Export
memory-helper.sh export --format json
memory-helper.sh export --format toon

# Graduation
memory-helper.sh graduate candidates
memory-helper.sh graduate graduate --dry-run
memory-helper.sh graduate graduate

# Namespaces
memory-helper.sh --namespace my-runner store --content "Runner-specific learning"
memory-helper.sh --namespace my-runner recall "query" --shared
memory-helper.sh namespaces
```

## Developer Preferences

Preference files complement the SQLite memory system for detailed, structured preferences:

```text
~/.aidevops/.agent-workspace/memory/preferences/
├── coding-style.md      # Indentation, line length, quote style, language-specific
├── documentation.md     # Comment density, JSDoc/PHPDoc, README format
├── workflow.md          # Git commit style, branch naming, testing, CI/CD
├── tools.md             # Editors, shell, Node/Python/package managers
└── project-specific/
    └── {project}.md     # Project-specific conventions and release process
```

**How AI assistants should use preferences:**
1. Before starting work: check `preferences/` for relevant files
2. During development: apply established preferences to suggestions and code
3. When feedback is given: update preference files to record new preferences
4. When switching projects: check for project-specific preference files

## Security Guidelines

- **Never store credentials** in memory files
- **Use configuration references** instead of actual API keys
- **Keep sensitive data** in `~/.config/aidevops/credentials.sh`
- **Regular cleanup** of outdated information
- **No personal identifiable information** in shareable templates
- **This directory is version controlled** — keep it clean; use `~/.aidevops/.agent-workspace/memory/` for all actual operations
