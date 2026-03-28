# Orchestration & Model Routing — Detail Reference

Loaded on-demand when working with the supervisor, model routing, or pattern tracking.
Core pointers are in `AGENTS.md`. Full docs: `tools/ai-assistants/headless-dispatch.md`, `.agents/scripts/commands/pulse.md`.

## Supervisor

`opencode` is the ONLY supported CLI for worker dispatch. Never use `claude` CLI. Always dispatch via `headless-runtime-helper.sh run` — never bare `opencode run` (GH#5096).

The `/pulse` command is the autonomous supervisor — an AI-driven agent that reads GitHub state (issues, PRs) and TODO.md directly, then dispatches workers via `headless-runtime-helper.sh run`. No SQLite state machine, no batches — GitHub and TODO.md are the database.

```bash
# Interactive dispatch of specific tasks
/runners t001 t002 t003

# Manual pulse (scheduler does this automatically every 2 minutes)
/pulse

# Install pulse scheduler (REQUIRED for autonomous operation)
# See scripts/commands/runners.md for macOS (launchd) and Linux (cron) setup
```

## Task Claiming

(t165): TODO.md `assignee:` field is the authoritative claim source. Works offline, with any git host. GitHub Issue sync is optional best-effort (requires `gh` CLI + `ref:GH#` in TODO.md). The `/full-loop` command claims the task automatically before starting work — if already claimed by another, the loop stops.

**Assignee ownership** (t1017): NEVER remove or change `assignee:` on a task without explicit user confirmation. The assignee may be a contributor on another host whose work you cannot see.

## Pulse Scheduler

Mandatory for autonomous operation. Without it, you must dispatch workers manually via `/runners`. The pulse cycle: check capacity -> scan GitHub state (pre-fetched) -> merge ready PRs -> dispatch workers for open issues -> sync TODOs. On macOS it uses launchd; on Linux, crontab. See `scripts/commands/runners.md` for setup instructions.

## Model Routing

Cost-aware routing matches task complexity to the optimal model tier. Use the cheapest model that produces acceptable quality.

**Tiers**: `haiku` (classification, formatting) → `flash` (large context, summarization) → `sonnet` (code, default) → `pro` (large codebase + reasoning) → `opus` (architecture, novel problems)

**Subagent frontmatter**: Add `model: <tier>` to YAML frontmatter. The supervisor resolves this to a concrete model during headless dispatch, with automatic cross-provider fallback.

**Commands**: `/route <task>` (suggest optimal tier with pattern data), `/compare-models` (side-by-side pricing/capabilities)

**Pre-dispatch availability**: `model-availability-helper.sh check <provider>` — cached health probes (~1-2s) verify providers are responding before dispatch. Exit codes: 0=available, 1=unavailable, 2=rate-limited, 3=invalid-key.

**Fallback chains**: Each tier has a primary model and cross-provider fallback (e.g., opus: claude-opus-4-6 → o3). The supervisor and `fallback-chain-helper.sh` handle this automatically.

**Budget-aware routing** (t1100): Two strategies based on billing model:

- **Token-billed APIs** (Anthropic direct, OpenRouter): Track daily spend per provider. Proactively degrade to cheaper tier when approaching budget cap (e.g., 80% of daily opus budget spent → route remaining to sonnet unless critical).
- **Subscription APIs** (OAuth with periodic allowances): Maximise utilisation within period. Prefer subscription providers when allowance is available to avoid token costs. Alert when approaching period limit.

**CLI**: `budget-tracker-helper.sh [record|check|recommend|status|configure|burn-rate]`

**Quick setup**:

```bash
# Configure Anthropic with $50/day budget
budget-tracker-helper.sh configure anthropic --billing-type token --daily-budget 50

# Configure OpenCode as subscription with monthly allowance
budget-tracker-helper.sh configure opencode --billing-type subscription
budget-tracker-helper.sh configure-period opencode --start 2026-02-01 --end 2026-03-01 --allowance 200
```

**Integration**: Dispatch.sh checks budget state before model selection. Spend is recorded automatically after each worker evaluation.

**Full docs**: `tools/context/model-routing.md`, `tools/ai-assistants/compare-models.md`

## Task Decomposition (t1408)

Pre-dispatch step that classifies tasks as atomic (execute directly) or composite (split into subtasks). Uses haiku-tier LLM calls (~$0.001 each) with heuristic fallback when API is unavailable.

**CLI**: `task-decompose-helper.sh [classify|decompose|format-lineage|has-subtasks]`

**Flow**: Task description → classify (atomic/composite) → if composite: decompose into 2-5 subtasks with dependency edges → create child TODO entries → dispatch leaf subtasks.

**Batch strategies** (for parallel dispatch of decomposed subtasks):

- **depth-first** (default): Complete all subtasks under one branch before starting the next. Good for dependent work where later subtasks build on earlier ones.
- **breadth-first**: One subtask from each branch per batch. Spreads progress evenly. Good for independent work.

The strategy is a recommendation from the decompose output, not a hard constraint. The pulse supervisor uses judgment for dispatch order, respecting `MAX_CONCURRENT_WORKERS` and `blocked-by:` edges.

**Depth limit**: `DECOMPOSE_MAX_DEPTH` (default: 3). Deeper decomposition suggests the original task was poorly scoped.

**Skip already-decomposed tasks**: `task-decompose-helper.sh has-subtasks <id>` checks TODO.md for existing child tasks. Prevents re-decomposition of manually split tasks.

**Full docs**: `todo/tasks/t1408-brief.md`

## Batch Execution Strategies (t1408.4)

When the task decomposition pipeline (t1408) splits a composite task into subtasks, batch strategies control the dispatch order. This is relevant when multiple subtasks share a parent and need coordinated parallel execution.

**Strategies:**

| Strategy | Behaviour | Best for |
|----------|-----------|----------|
| depth-first (default) | Complete all subtasks under one branch before starting the next | Dependent work, sequential integration |
| breadth-first | One subtask from each branch per batch | Independent work, even progress |

```text
depth-first (concurrency=2):       breadth-first (concurrency=3):
  t1.1, t1.2 ─ batch 1              t1.1, t2.1, t3.1 ─ batch 1
  t1.3       ─ batch 2              t1.2, t2.2, t3.2 ─ batch 2
  t2.1, t2.2 ─ batch 3              t1.3, t2.3       ─ batch 3
  t3.1       ─ batch 4
```

**CLI**: `batch-strategy-helper.sh [order|next-batch|validate] --strategy <strategy> --tasks <json> --concurrency <N>`

**Integration**: The pulse supervisor uses `batch-strategy-helper.sh next-batch` when dispatching decomposed subtasks. Batch sizes are capped by available worker slots (`AVAILABLE` from Step 1). The helper respects `blocked_by:` dependencies — blocked tasks are excluded from batches until their blockers complete.

**Configuration**: `BATCH_STRATEGY` env var (default: `depth-first`). Can be overridden per-repo via bundle config or per-task via the decomposition pipeline.

**Full docs**: `.agents/scripts/commands/pulse.md` "Batch execution strategies" section, `scripts/batch-strategy-helper.sh help`

## Pattern Tracking

Track success/failure patterns across task types, models, and approaches. Patterns feed into model routing recommendations for data-driven dispatch.

**How it works**: The pulse supervisor observes outcomes from GitHub state (Step 2a) and agents record patterns via cross-session memory (`/remember`, `/recall`). No separate CLI or database — GitHub issues/PRs and the memory system are the sources of truth.

**Commands**: `/patterns <task>` (suggest approach), `/patterns report` (full report), `/patterns recommend <type>` (model recommendation)

**Automatic capture**: The pulse supervisor observes success/failure patterns from GitHub PR state (merged vs closed-without-merge) and files improvement issues when patterns emerge.

**Integration with model routing**: `/route <task>` combines routing rules with pattern history. If pattern data shows >75% success rate with 3+ samples for a tier, it is weighted heavily in the recommendation.

**Full docs**: `reference/memory.md` "Pattern Tracking" section, `scripts/commands/patterns.md`
