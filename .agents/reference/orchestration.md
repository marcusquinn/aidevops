# Orchestration & Model Routing — Detail Reference

Core pointers: `AGENTS.md`. Full docs: `tools/ai-assistants/headless-dispatch.md`, `scripts/commands/pulse.md`.

## Supervisor

- `opencode` is the ONLY supported CLI for worker dispatch. Never use `claude` CLI. Always dispatch via `headless-runtime-helper.sh run` — never bare `opencode run` (GH#5096).
- `/pulse` is the autonomous supervisor. Reads GitHub state (issues, PRs) and `TODO.md`, dispatches workers via `headless-runtime-helper.sh run`. GitHub + `TODO.md` are the database; do not add SQLite/state-machine layers.
- Without the pulse scheduler, dispatch manually via `/runners`. Cycle: check capacity → scan prefetched GitHub state → merge ready PRs → dispatch open issues → sync TODOs. macOS: launchd; Linux: cron. Setup: `scripts/commands/runners.md`.

## Task Claiming

- (t165) `TODO.md` `assignee:` is the authoritative claim source. Works offline and with any git host. GitHub issue sync is optional best-effort and requires `gh` CLI plus `ref:GH#` in `TODO.md`.
- `/full-loop` claims the task automatically before work starts. If another assignee already holds it, the loop stops.
- **Assignee ownership** (t1017): never remove or change `assignee:` without explicit user confirmation. The assignee may be a contributor on another host whose work you cannot see.

## Model Routing

- **Tiers**: `haiku` (classification, formatting) → `flash` (large context, summarization) → `sonnet` (code, default) → `pro` (large codebase + reasoning) → `opus` (architecture, novel problems)
- **Subagent frontmatter**: add `model: <tier>` to YAML frontmatter. The supervisor resolves it to a concrete model during headless dispatch, with cross-provider fallback.
- **Commands**: `/route <task>` for tier suggestions with pattern data, `/compare-models` for pricing/capabilities.
- **Availability check**: `model-availability-helper.sh check <provider>`. Exit codes: 0=available, 1=unavailable, 2=rate-limited, 3=invalid-key.
- **Fallback chains**: each tier has a primary model plus cross-provider fallback (e.g., `opus`: `claude-opus-4-6` → `o3`). Handled automatically by `fallback-chain-helper.sh`.

### Budget-aware routing (t1100)

- **Token-billed APIs** (Anthropic direct, OpenRouter): track daily spend; degrade when nearing budget caps (e.g., 80% of daily opus budget → route to sonnet unless critical).
- **Subscription APIs** (OAuth with periodic allowances): maximise use within the allowance window; alert near period limits.
- **CLI**: `budget-tracker-helper.sh [record|check|recommend|status|configure|burn-rate]`. Configure: `budget-tracker-helper.sh configure anthropic --billing-type token --daily-budget 50` or `configure-period opencode --start YYYY-MM-DD --end YYYY-MM-DD --allowance 200`.
- **Integration**: `dispatch.sh` checks budget state before model selection. Spend recorded automatically after each worker evaluation.

Full docs: `tools/context/model-routing.md`, `tools/ai-assistants/compare-models.md`

## Task Decomposition (t1408)

- Pre-dispatch, classify each task as atomic (execute directly) or composite (split into subtasks). Uses haiku-tier calls (~$0.001 each) with heuristic fallback when API is unavailable.
- **CLI**: `task-decompose-helper.sh [classify|decompose|format-lineage|has-subtasks]`
- **Flow**: task description → classify → if composite, decompose into 2-5 subtasks with dependency edges → create child `TODO.md` entries → dispatch leaf subtasks.
- `task-decompose-helper.sh has-subtasks <id>` prevents re-decomposition of manually split work.
- **Depth limit**: `DECOMPOSE_MAX_DEPTH` (default `3`). Deeper trees indicate poor task scope.

### Batch execution strategies (t1408.4)

Decomposition output can recommend dispatch order, but the pulse supervisor respects `MAX_CONCURRENT_WORKERS` and `blocked-by:` edges.

| Strategy | Behaviour | Best for |
|----------|-----------|----------|
| `depth-first` (default) | Complete all subtasks under one branch before starting the next | Dependent work, sequential integration |
| `breadth-first` | Dispatch one subtask from each branch per batch | Independent work, even progress |

- **CLI**: `batch-strategy-helper.sh [order|next-batch|validate] --strategy <strategy> --tasks <json> --concurrency <N>`
- **Integration**: pulse supervisor uses `batch-strategy-helper.sh next-batch`; blocked tasks stay out of batches until blockers clear.
- **Configuration**: `BATCH_STRATEGY` env var (default: `depth-first`). Override per repo via bundle config or per task via the decomposition pipeline.

Full docs: `todo/tasks/t1408-brief.md`, `scripts/commands/pulse.md` "Batch execution strategies", `scripts/batch-strategy-helper.sh help`

## Pattern Tracking

- Track success and failure patterns across task types, models, and approaches so routing becomes data-driven.
- Source of truth: GitHub issues/PRs plus cross-session memory (`/remember`, `/recall`). Do not introduce a separate pattern database.
- **Commands**: `/patterns <task>`, `/patterns report`, `/patterns recommend <type>`
- **Automatic capture**: pulse supervisor observes PR outcomes (merged vs closed-without-merge) and files improvement issues when patterns emerge.
- **Routing integration**: `/route <task>` combines routing rules with pattern history. Tier with >75% success at 3+ samples is weighted heavily.

Full docs: `reference/memory.md` "Pattern Tracking" section, `scripts/commands/patterns.md`
