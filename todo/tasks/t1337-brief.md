---
mode: subagent
---
# t1337: Simplify Tier 3 scripts — reduce over-engineered infrastructure to AI-readable config

## Origin

- **Created:** 2026-02-25
- **Session:** claude-code:self-improvement-agent-routing
- **Created by:** human + ai-interactive
- **Parent task:** none (sibling of t1335, t1336)
- **Conversation context:** After archiving Tier 1 (pulse-duplicated) and Tier 2 (over-engineered loops), these Tier 3 scripts serve legitimate purposes but are far larger than they need to be. They can be simplified from bash logic to AI-readable configuration + thin wrappers, reducing ~8,300 lines to ~2,000 while preserving functionality.

## What

Simplify 5 scripts (~8,346 lines total) that serve legitimate infrastructure purposes but are over-engineered. The goal is NOT to archive them but to reduce their complexity by replacing bash decision-making with AI-readable configuration files and thin shell wrappers.

**Scripts to simplify:**

| Script | Current | Target | Strategy |
|--------|---------|--------|----------|
| `full-loop-helper.sh` | 1,169 | ~400 | Remove phases that AI handles (task resolution, README gate). Keep worktree management, headless mode, phase state. The `.md` prompt already tells AI what to do — the `.sh` shouldn't duplicate those decisions. |
| `fallback-chain-helper.sh` | 1,367 | ~200 | Replace bash chain resolution with a TOON/JSON model routing table that AI reads directly. Keep only the `is_model_available()` health check function. AI decides fallback order, not bash. |
| `budget-tracker-helper.sh` | 1,671 | ~300 | Replace SQLite budget tracking with a simple cost log file (append-only). AI reads the log and decides whether to use a cheaper model. Remove the 1,300 lines of billing strategy, threshold logic, and alert routing. |
| `issue-sync-helper.sh` | 2,398 | ~600 | This is data plumbing (TODO.md ↔ GitHub issues). Keep the sync logic but remove the SQLite intermediate store. Sync directly between TODO.md and `gh` CLI. The current script has a full ORM layer for a sync that should be stateless. |
| `observability-helper.sh` | 1,741 | ~500 | Keep metrics collection but remove the SQLite analytics store. Write metrics to a simple log file. AI can read logs; it doesn't need a query interface. The dashboarding logic (1,000+ lines) is unused. |

**SQLite databases to remove after simplification:**
- Budget tracker DB — replace with append-only cost log
- Observability DB — replace with structured log file
- Issue sync intermediate DB — remove entirely (sync is TODO.md ↔ GitHub, no intermediate needed)

**Key principle:** Git is the audit trail. Append-only log files are fine for operational data. SQLite databases that duplicate GitHub state are not.

## Why

- **Complexity without value:** 8,346 lines of bash for infrastructure that could be 2,000 lines + AI judgment. The extra 6,000 lines are decision-making logic that AI handles better.
- **SQLite divergence:** Three more SQLite databases maintaining state that either duplicates GitHub (issue-sync) or could be a flat file (budget, observability). Each is a divergence risk.
- **full-loop-helper.sh is the critical path:** Every worker runs through it. Simplifying it reduces the surface area for bugs and makes worker behaviour more predictable.
- **Model routing should be declarative:** The fallback chain is 1,367 lines of bash resolving model availability through provider chains. A 20-line TOON table + `curl` health check would do the same thing and be readable by AI.

## How (Approach)

This is a multi-PR task. Each script should be simplified in its own PR to isolate risk:

### PR 1: full-loop-helper.sh (~1,169 → ~400 lines)

1. Read `full-loop.md` and `full-loop-helper.sh` side by side.
2. Identify functions in the `.sh` that duplicate instructions in the `.md` (task resolution, README gate, quality decisions).
3. Remove duplicated logic — the AI reads the `.md` and makes these decisions.
4. Keep: worktree management, phase state file, headless mode detection, `gh` auth verification, rebase/push mechanics.
5. Test: Run `/full-loop` on a small task end-to-end.

### PR 2: fallback-chain-helper.sh (~1,367 → ~200 lines)

1. Create `.agents/configs/model-routing.toon` with the fallback chain as a declarative table.
2. Reduce the script to: read the table, check model availability via API health endpoint, return the first available model.
3. Remove: chain resolution logic, per-agent overrides in bash, retry/backoff logic (AI handles retries).
4. Test: Verify model selection still works when primary model is down.

### PR 3: budget-tracker-helper.sh (~1,671 → ~300 lines)

1. Replace SQLite with an append-only cost log: `~/.aidevops/logs/cost.log` (timestamp, model, tokens, cost).
2. Keep: cost logging function, daily/monthly summary function.
3. Remove: billing strategy logic, threshold alerts, model downgrade routing (AI reads the log and decides).
4. Test: Verify cost logging works, verify AI can read the log and report spend.

### PR 4: issue-sync-helper.sh (~2,398 → ~600 lines)

1. Remove the SQLite intermediate store.
2. Sync directly: read TODO.md → compare with `gh issue list` → create/update/close issues.
3. Keep: the TODO.md parser, the `gh` CLI calls, the label mapping.
4. Remove: the ORM layer, the conflict resolution logic (let AI handle conflicts), the batch optimization.
5. Test: Run `issue-sync-helper.sh` and verify TODO.md ↔ GitHub issues are in sync.

### PR 5: observability-helper.sh (~1,741 → ~500 lines)

1. Replace SQLite with structured log: `~/.aidevops/logs/observability.log` (JSON lines).
2. Keep: metric collection functions, health check functions.
3. Remove: the analytics query interface, the dashboarding logic, the SQLite schema management.
4. Test: Verify health checks still work, verify metrics are logged.

## Acceptance Criteria

- [ ] `full-loop-helper.sh` reduced to <500 lines with no loss of worker functionality
  ```yaml
  verify:
    method: bash
    run: "wc -l < .agents/scripts/full-loop-helper.sh | awk '{exit ($1 > 500)}'"
  ```
- [ ] `/full-loop` end-to-end test passes (branch → implement → PR → merge)
  ```yaml
  verify:
    method: manual
    prompt: "Run /full-loop on a trivial task (e.g., fix a typo). Verify it completes all phases through merge."
  ```
- [ ] `fallback-chain-helper.sh` reduced to <300 lines with model routing table in TOON/JSON
  ```yaml
  verify:
    method: bash
    run: "wc -l < .agents/scripts/fallback-chain-helper.sh | awk '{exit ($1 > 300)}'"
  ```
- [ ] `budget-tracker-helper.sh` reduced to <400 lines, SQLite replaced with append-only log
  ```yaml
  verify:
    method: bash
    run: "wc -l < .agents/scripts/budget-tracker-helper.sh | awk '{exit ($1 > 400)}' && ! rg -q 'sqlite' .agents/scripts/budget-tracker-helper.sh"
  ```
- [ ] `issue-sync-helper.sh` reduced to <800 lines, no SQLite intermediate store
  ```yaml
  verify:
    method: bash
    run: "wc -l < .agents/scripts/issue-sync-helper.sh | awk '{exit ($1 > 800)}' && ! rg -q 'sqlite' .agents/scripts/issue-sync-helper.sh"
  ```
- [ ] `observability-helper.sh` reduced to <600 lines, SQLite replaced with JSON log
  ```yaml
  verify:
    method: bash
    run: "wc -l < .agents/scripts/observability-helper.sh | awk '{exit ($1 > 600)}' && ! rg -q 'sqlite' .agents/scripts/observability-helper.sh"
  ```
- [ ] No SQLite databases remain in `.agent-workspace/` for budget, observability, or issue-sync
  ```yaml
  verify:
    method: bash
    run: "fd -e db ~/.aidevops/.agent-workspace/ 2>/dev/null | grep -iE 'budget|observ|issue.sync' | wc -l | grep -q '^0$'"
  ```
- [ ] All existing tests still pass after simplification
- [ ] ShellCheck clean on all modified `.sh` files
- [ ] Markdown lint clean on all modified `.md` files

## Context & Decisions

- **Why simplify, not archive:** These scripts serve real purposes (worktree management, model routing, cost tracking, issue sync, monitoring). The problem is they're 4-8x larger than they need to be because they implement decision-making that AI handles better.
- **Multi-PR approach:** Each script is independent. Simplifying one shouldn't break another. Separate PRs isolate risk and allow rollback per-script.
- **full-loop-helper.sh is highest risk:** Every worker depends on it. Simplify conservatively — remove only what the `.md` prompt already covers. Test extensively.
- **Append-only logs over SQLite:** For operational data (costs, metrics), an append-only log is simpler, has no schema migration issues, and AI can read it directly. SQLite adds complexity for data that doesn't need relational queries.
- **TOON for model routing:** The fallback chain is naturally a table (model → provider → fallback). TOON format is already used in the framework (`subagent-index.toon`). AI reads TOON natively.
- **Git is the audit trail:** Issue sync doesn't need an intermediate database. TODO.md is in git (full history). GitHub issues have full history. The sync should be stateless: compare and reconcile.

## Relevant Files

- `.agents/scripts/full-loop-helper.sh` — 1,169 lines, worker phase orchestrator
- `.agents/scripts/commands/full-loop.md` — 455 lines, worker AI prompt (the authority)
- `.agents/scripts/fallback-chain-helper.sh` — 1,367 lines, model fallback resolution
- `.agents/scripts/budget-tracker-helper.sh` — 1,671 lines, cost tracking + model routing
- `.agents/scripts/issue-sync-helper.sh` — 2,398 lines, TODO.md ↔ GitHub sync
- `.agents/scripts/observability-helper.sh` — 1,741 lines, metrics + monitoring
- `.agents/scripts/shared-constants.sh` — may have constants to update
- `.agents/configs/` — target for new config files (model-routing.toon)

## Dependencies

- **Blocked by:** t1335 (Tier 1 archive), t1336 (Tier 2 archive) — validate the pattern first
- **Blocks:** nothing directly, but reduces maintenance burden for all future work
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Read all 5 scripts, identify what to keep vs remove |
| PR 1: full-loop-helper | 2h | Highest risk, most testing needed |
| PR 2: fallback-chain | 1h | Create TOON table, thin wrapper |
| PR 3: budget-tracker | 1h | Replace SQLite with log file |
| PR 4: issue-sync | 1.5h | Remove ORM, direct sync |
| PR 5: observability | 1h | Replace SQLite with JSON log |
| Integration testing | 1h | Full system soak test |
| **Total** | **~8.5h** | 5 PRs, can be parallelized across workers |
