# Orchestration & Model Routing — Detail Reference

Loaded on-demand when working with the supervisor, model routing, or pattern tracking.
Core pointers are in `AGENTS.md`. Full docs: `tools/ai-assistants/headless-dispatch.md`, `supervisor-helper.sh help`.

## Supervisor CLI

`opencode` is the ONLY supported CLI for worker dispatch. Never use `claude` CLI.

`supervisor-helper.sh` manages parallel task execution with SQLite state machine.

```bash
# Add tasks and create batch
supervisor-helper.sh add t001 --repo "$(pwd)" --description "Task description"
supervisor-helper.sh batch "my-batch" --concurrency 3 --tasks "t001,t002,t003"

# Task claiming (t165 — provider-agnostic, TODO.md primary)
supervisor-helper.sh claim t001     # Adds assignee: to TODO.md, optional GH sync
supervisor-helper.sh unclaim t001   # Releases claim (removes assignee:)
# Claiming is automatic during dispatch. Manual claim/unclaim for coordination.

# Install pulse scheduler (REQUIRED for autonomous operation)
# macOS: installs ~/Library/LaunchAgents/com.aidevops.supervisor-pulse.plist
# Linux: installs crontab entry
supervisor-helper.sh cron install

# Manual pulse (scheduler does this automatically every 2 minutes)
supervisor-helper.sh pulse --batch <batch-id>

# Monitor
supervisor-helper.sh dashboard --batch <batch-id>
supervisor-helper.sh status <batch-id>
```

## Task Claiming

(t165): TODO.md `assignee:` field is the authoritative claim source. Works offline, with any git host. GitHub Issue sync is optional best-effort (requires `gh` CLI + `ref:GH#` in TODO.md). GH Issue creation is opt-in: use `--with-issue` flag or `SUPERVISOR_AUTO_ISSUE=true`.

**Assignee ownership** (t1017): NEVER remove or change `assignee:` on a task without explicit user confirmation. The assignee may be a contributor on another host whose work you cannot see. `unclaim` requires `--force` to release a task claimed by someone else. The full-loop claims the task automatically before starting work — if the task is already claimed by another, the loop stops.

## Pulse Scheduler

Mandatory for autonomous operation. Without it, the supervisor is passive and requires manual `pulse` calls. The pulse cycle: check workers -> evaluate outcomes -> dispatch next -> cleanup. On macOS, `cron install` uses launchd (no cron dependency); on Linux, it uses crontab.

## Session Memory Monitoring + Respawn

(t264, t264.1): Long-running OpenCode/Bun sessions accumulate WebKit malloc dirty pages that are never returned to the OS (25GB+ observed). Phase 11 of the pulse cycle checks the parent session's `phys_footprint` when a batch wave completes (no running/queued tasks). If memory exceeds `SUPERVISOR_SELF_MEM_LIMIT` (default: 8192MB), it saves a checkpoint, logs the respawn event to `~/.aidevops/logs/respawn-history.log`, and exits cleanly for the next cron pulse to start fresh. Use `supervisor-helper.sh mem-check` to inspect memory and `supervisor-helper.sh respawn-history` to review respawn patterns.

## Model Routing

Cost-aware routing matches task complexity to the optimal model tier. Use the cheapest model that produces acceptable quality.

**Tiers**: `haiku` (classification, formatting) → `flash` (large context, summarization) → `sonnet` (code, default) → `pro` (large codebase + reasoning) → `opus` (architecture, novel problems)

**Subagent frontmatter**: Add `model: <tier>` to YAML frontmatter. The supervisor resolves this to a concrete model during headless dispatch, with automatic cross-provider fallback.

**Commands**: `/route <task>` (suggest optimal tier with pattern data), `/compare-models` (side-by-side pricing/capabilities)

**Pre-dispatch availability**: `model-availability-helper.sh check <provider>` — cached health probes (~1-2s) verify providers are responding before dispatch. Exit codes: 0=available, 1=unavailable, 2=rate-limited, 3=invalid-key.

**Fallback chains**: Each tier has a primary model and cross-provider fallback (e.g., opus: claude-opus-4 → o3). The supervisor and `fallback-chain-helper.sh` handle this automatically.

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

## Pattern Tracking

Track success/failure patterns across task types, models, and approaches. Patterns feed into model routing recommendations for data-driven dispatch.

**CLI**: `pattern-tracker-helper.sh [record|suggest|recommend|analyze|stats|report|export]`

**Commands**: `/patterns <task>` (suggest approach), `/patterns report` (full report), `/patterns recommend <type>` (model recommendation)

**Automatic capture**: The supervisor stores `SUCCESS_PATTERN` and `FAILURE_PATTERN` entries after each task evaluation, tagged with model tier, duration, and retry count.

**Integration with model routing**: `/route <task>` combines routing rules with pattern history. If pattern data shows >75% success rate with 3+ samples for a tier, it is weighted heavily in the recommendation.

**Full docs**: `memory/README.md` "Pattern Tracking" section, `scripts/commands/patterns.md`
