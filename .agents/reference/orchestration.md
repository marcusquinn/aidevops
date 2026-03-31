# Orchestration & Model Routing — Detail Reference

Loaded on demand for supervisor behaviour, model routing, task decomposition, and pattern tracking. Core pointers live in `AGENTS.md`. Full docs: `tools/ai-assistants/headless-dispatch.md`, `.agents/scripts/commands/pulse.md`.

## Supervisor

- `opencode` is the ONLY supported CLI for worker dispatch. Never use `claude` CLI. Always dispatch via `headless-runtime-helper.sh run` — never bare `opencode run` (GH#5096).
- `/pulse` is the autonomous supervisor. It reads GitHub state (issues, PRs) and `TODO.md` directly, then dispatches workers via `headless-runtime-helper.sh run`. GitHub + `TODO.md` are the database; do not add SQLite/state-machine layers.
- Autonomous operation requires the pulse scheduler. Without it, dispatch workers manually via `/runners`. Cycle: check capacity → scan prefetched GitHub state → merge ready PRs → dispatch open issues → sync TODOs. macOS uses launchd; Linux uses cron. Setup: `scripts/commands/runners.md`.

```bash
# Interactive dispatch of specific tasks
/runners t001 t002 t003

# Manual pulse (scheduler does this automatically every 2 minutes)
/pulse

# Install pulse scheduler (REQUIRED for autonomous operation)
# See scripts/commands/runners.md for macOS (launchd) and Linux (cron) setup
```

## Task Claiming

- (t165) `TODO.md` `assignee:` is the authoritative claim source. It works offline and with any git host. GitHub issue sync is optional best-effort and requires `gh` CLI plus `ref:GH#` in `TODO.md`.
- `/full-loop` claims the task automatically before work starts. If another assignee already holds it, the loop stops.
- **Assignee ownership** (t1017): never remove or change `assignee:` without explicit user confirmation. The assignee may be a contributor on another host whose work you cannot see.

## Model Routing

Use the cheapest model that still produces acceptable quality.

- **Tiers**: `haiku` (classification, formatting) → `flash` (large context, summarization) → `sonnet` (code, default) → `pro` (large codebase + reasoning) → `opus` (architecture, novel problems)
- **Subagent frontmatter**: add `model: <tier>` to YAML frontmatter. The supervisor resolves it to a concrete model during headless dispatch, with cross-provider fallback.
- **Commands**: `/route <task>` for tier suggestions with pattern data, `/compare-models` for pricing/capabilities.
- **Availability check**: `model-availability-helper.sh check <provider>` runs cached health probes (~1-2s). Exit codes: 0=available, 1=unavailable, 2=rate-limited, 3=invalid-key.
- **Fallback chains**: each tier has a primary model plus cross-provider fallback (for example `opus`: `claude-opus-4-6` → `o3`). The supervisor and `fallback-chain-helper.sh` handle this automatically.

### Budget-aware routing (t1100)

- **Token-billed APIs** (Anthropic direct, OpenRouter): track daily spend per provider and proactively degrade when nearing budget caps (for example 80% of daily opus budget spent → route remaining work to sonnet unless critical).
- **Subscription APIs** (OAuth with periodic allowances): maximise use within the allowance window, prefer subscription providers when available, and alert near period limits.
- **CLI**: `budget-tracker-helper.sh [record|check|recommend|status|configure|burn-rate]`
- **Integration**: `dispatch.sh` checks budget state before model selection. Spend is recorded automatically after each worker evaluation.

```bash
# Configure Anthropic with $50/day budget
budget-tracker-helper.sh configure anthropic --billing-type token --daily-budget 50

# Configure OpenCode as subscription with monthly allowance
budget-tracker-helper.sh configure opencode --billing-type subscription
budget-tracker-helper.sh configure-period opencode --start 2026-02-01 --end 2026-03-01 --allowance 200
```

Full docs: `tools/context/model-routing.md`, `tools/ai-assistants/compare-models.md`

## Task Decomposition (t1408)

- Pre-dispatch, classify each task as atomic (execute directly) or composite (split into subtasks). The helper uses haiku-tier calls (~$0.001 each) with heuristic fallback when the API is unavailable.
- **CLI**: `task-decompose-helper.sh [classify|decompose|format-lineage|has-subtasks]`
- **Flow**: task description → classify → if composite, decompose into 2-5 subtasks with dependency edges → create child `TODO.md` entries → dispatch leaf subtasks.
- `task-decompose-helper.sh has-subtasks <id>` checks for existing child tasks and prevents re-decomposition of manually split work.
- **Depth limit**: `DECOMPOSE_MAX_DEPTH` (default `3`). Deeper trees indicate poor task scope.

### Batch execution strategies (t1408.4)

The decomposition output can recommend a dispatch order, but the pulse supervisor still uses judgment and respects `MAX_CONCURRENT_WORKERS` plus `blocked-by:` edges.

| Strategy | Behaviour | Best for |
|----------|-----------|----------|
| `depth-first` (default) | Complete all subtasks under one branch before starting the next | Dependent work, sequential integration |
| `breadth-first` | Dispatch one subtask from each branch per batch | Independent work, even progress |

```text
depth-first (concurrency=2):       breadth-first (concurrency=3):
  t1.1, t1.2 ─ batch 1              t1.1, t2.1, t3.1 ─ batch 1
  t1.3       ─ batch 2              t1.2, t2.2, t3.2 ─ batch 2
  t2.1, t2.2 ─ batch 3              t1.3, t2.3       ─ batch 3
  t3.1       ─ batch 4
```

- **CLI**: `batch-strategy-helper.sh [order|next-batch|validate] --strategy <strategy> --tasks <json> --concurrency <N>`
- **Integration**: the pulse supervisor uses `batch-strategy-helper.sh next-batch`; blocked tasks stay out of batches until blockers clear.
- **Configuration**: `BATCH_STRATEGY` env var (default: `depth-first`). Override per repo via bundle config or per task via the decomposition pipeline.

Full docs: `todo/tasks/t1408-brief.md`, `.agents/scripts/commands/pulse.md` "Batch execution strategies", `scripts/batch-strategy-helper.sh help`

## Pattern Tracking

- Track success and failure patterns across task types, models, and approaches so routing becomes data-driven.
- Source of truth: GitHub issues/PRs plus cross-session memory (`/remember`, `/recall`). Do not introduce a separate pattern database.
- **Commands**: `/patterns <task>`, `/patterns report`, `/patterns recommend <type>`
- **Automatic capture**: the pulse supervisor observes PR outcomes (merged vs closed-without-merge) and files improvement issues when patterns emerge.
- **Routing integration**: `/route <task>` combines routing rules with pattern history. If a tier shows >75% success with 3+ samples, weight it heavily in the recommendation.

Full docs: `reference/memory.md` "Pattern Tracking" section, `scripts/commands/patterns.md`
