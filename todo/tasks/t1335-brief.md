---
mode: subagent
---
# t1335: Archive Tier 1 redundant orchestration scripts — pulse-duplicated decision-makers

## Origin

- **Created:** 2026-02-25
- **Session:** claude-code:self-improvement-agent-routing
- **Created by:** human + ai-interactive
- **Parent task:** none
- **Conversation context:** After replacing the 37K-line bash supervisor with a 123-line AI pulse system (PR #2291), we audited remaining scripts and found ~6,000 lines of bash that duplicate what the pulse + AGENTS.md self-improvement principle now handle. These scripts make decisions that AI should make, using SQLite state that duplicates GitHub.

## What

Archive 7 scripts (~5,956 lines) to `.agents/scripts/archived/` that are now redundant with the pulse supervisor's self-improvement observation (AGENTS.md "Self-Improvement" section) and GitHub-as-state-DB principle. Remove any SQLite databases these scripts created at runtime, since GitHub issues/PRs/TODO.md are the authoritative state.

**Scripts to archive:**

| Script | Lines | Replaced by |
|--------|-------|-------------|
| `pattern-tracker-helper.sh` | 2,138 | Pulse Step 2a observes patterns from GitHub state |
| `self-improve-helper.sh` | 773 | AGENTS.md "Self-Improvement" — universal principle for all agents |
| `stale-pr-helper.sh` | 688 | Pulse Step 2a checks for stale PRs (6h+ no progress) |
| `finding-to-task-helper.sh` | 697 | AI reads quality tool output and creates better-scoped tasks |
| `coordinator-helper.sh` | 401 | Pulse IS the coordinator — stateless, GitHub-driven |
| `batch-cleanup-helper.sh` | 587 | Pulse already batches — fills available slots with highest-value items |
| `circuit-breaker-helper.sh` | 672 | See verification note below |

**SQLite databases to remove (runtime only, not in git):**
- `~/.aidevops/.agent-workspace/supervisor/supervisor.db` (if exists)
- Any `pattern-tracker*.db`, `budget*.db`, `coordinator*.db` files in `.agent-workspace/`

**circuit-breaker-helper.sh special case:** This was just added by a worker (PR #2294) and is referenced by `pulse.md` Step 0 and Step 5. It must be verified that the pulse's Step 2a outcome observation (checking `gh pr list --state closed` for failures) provides equivalent protection before archiving. If not, keep it and remove from this task's scope.

## Why

- **Divergence risk:** These scripts maintain SQLite state that duplicates GitHub. Two sources of truth = inevitable divergence.
- **Deterministic gates override AI:** The pattern tracker and circuit breaker make routing decisions with fixed thresholds that prevent AI from exercising judgment.
- **Maintenance burden:** 5,956 lines of bash that nobody reads, with zero external references (confirmed via `rg`). They're dead code that could confuse future workers.
- **Proven replacement:** The pulse system merged 20+ PRs in its first 4 hours with zero bash orchestration scripts. The AI-driven approach works.

## How (Approach)

1. **Verify zero callers:** Run `rg -l "<script-name>" .agents/ --include '*.md' --include '*.sh' | grep -v archived` for each script. Confirmed zero for all except `circuit-breaker-helper.sh` (referenced by `pulse.md`).
2. **Move scripts:** `git mv .agents/scripts/<script>.sh .agents/scripts/archived/<script>.sh` for each.
3. **Move test files:** `git mv .agents/scripts/tests/test-circuit-breaker.sh .agents/scripts/archived/` (if circuit breaker is archived).
4. **Update pulse.md:** If circuit breaker is archived, remove Step 0 and Step 5 references. The pulse's Step 2a already observes failure patterns from GitHub.
5. **Clean shared-constants.sh:** Remove any constants that only these scripts used (check with `rg`).
6. **Remove runtime SQLite DBs:** Document which files to remove from `~/.aidevops/.agent-workspace/` and add a cleanup step to `setup.sh` or document manual removal.
7. **Update AGENTS.md:** Remove any remaining references to `supervisor.db` or these scripts.
8. **Test:** Run the pulse for 30+ minutes after archiving and verify it still dispatches, merges, and observes outcomes correctly.

## Acceptance Criteria

- [ ] All 7 scripts (or 6 if circuit breaker is kept) moved to `.agents/scripts/archived/`
  ```yaml
  verify:
    method: bash
    run: "ls .agents/scripts/archived/pattern-tracker-helper.sh .agents/scripts/archived/self-improve-helper.sh .agents/scripts/archived/stale-pr-helper.sh .agents/scripts/archived/finding-to-task-helper.sh .agents/scripts/archived/coordinator-helper.sh .agents/scripts/archived/batch-cleanup-helper.sh 2>/dev/null | wc -l | grep -q '[6-7]'"
  ```
- [ ] Zero references to archived scripts from active code (excluding archived/ directory)
  ```yaml
  verify:
    method: bash
    run: "rg -l 'pattern-tracker-helper|self-improve-helper|stale-pr-helper|finding-to-task-helper|coordinator-helper|batch-cleanup-helper' .agents/ --include '*.md' --include '*.sh' 2>/dev/null | grep -v archived | wc -l | grep -q '^0$'"
  ```
- [ ] No references to `supervisor.db` in active code
  ```yaml
  verify:
    method: bash
    run: "rg -l 'supervisor\.db' .agents/ --include '*.md' --include '*.sh' 2>/dev/null | grep -v archived | wc -l | grep -q '^0$'"
  ```
- [ ] Pulse continues to fire and dispatch workers after archiving (30-minute soak test)
  ```yaml
  verify:
    method: manual
    prompt: "Check pulse.log timestamps span 30+ minutes after merge. Verify at least 1 worker was dispatched."
  ```
- [ ] Pulse Step 2a still detects stale PRs and failure patterns (replaces stale-pr-helper and pattern-tracker)
  ```yaml
  verify:
    method: manual
    prompt: "Create a test scenario: close a PR without merging. On next pulse, verify the pulse observes it and either files an issue or notes it in output."
  ```
- [ ] Markdown lint clean on all modified .md files
  ```yaml
  verify:
    method: bash
    run: "npx markdownlint-cli2 .agents/AGENTS.md .agents/scripts/commands/pulse.md 2>&1 | grep -q '0 error'"
  ```

## Context & Decisions

- **Why archive, not delete:** Git history preserves the code, but archiving makes it clear these are deprecated. Workers won't accidentally call them. Same pattern used for the 29 supervisor scripts (PR #2291).
- **Why GitHub over SQLite:** GitHub issues/PRs are already the source of truth. SQLite was a parallel state store that inevitably diverged. Git is the audit trail — no need for a separate database.
- **Circuit breaker is the edge case:** It was just added (PR #2294) and is actively referenced. The decision to archive it depends on whether pulse Step 2a provides equivalent failure detection. If not, keep it — it's only 672 lines and serves a legitimate safety function.
- **No data migration needed:** The SQLite databases contain derived data (patterns, budgets, findings) that can be reconstructed from GitHub history. They are not primary-source information.

## Relevant Files

- `.agents/scripts/pattern-tracker-helper.sh` — 2,138 lines, SQLite pattern tracking
- `.agents/scripts/self-improve-helper.sh` — 773 lines, bash self-improvement
- `.agents/scripts/stale-pr-helper.sh` — 688 lines, stale PR detection
- `.agents/scripts/finding-to-task-helper.sh` — 697 lines, quality findings → tasks
- `.agents/scripts/coordinator-helper.sh` — 401 lines, SQLite multi-agent coordinator
- `.agents/scripts/batch-cleanup-helper.sh` — 587 lines, batch chore dispatch
- `.agents/scripts/circuit-breaker-helper.sh` — 672 lines, failure circuit breaker
- `.agents/scripts/commands/pulse.md` — references circuit-breaker-helper
- `.agents/AGENTS.md:39-60` — Self-Improvement section (the replacement)
- `.agents/scripts/shared-constants.sh` — may have constants to clean up

## Dependencies

- **Blocked by:** nothing — these scripts have zero callers
- **Blocks:** t1336 (Tier 2 archive) — should be done first to validate the archive pattern
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Verify zero callers, check circuit breaker decision |
| Implementation | 30m | git mv, update references, clean constants |
| Testing | 30m | 30-minute pulse soak test |
| **Total** | **~1.5h** | |
