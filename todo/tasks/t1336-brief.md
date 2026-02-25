---
mode: subagent
---
# t1336: Archive Tier 2 redundant orchestration scripts — over-engineered loops and quality pipelines

## Origin

- **Created:** 2026-02-25
- **Session:** claude-code:self-improvement-agent-routing
- **Created by:** human + ai-interactive
- **Parent task:** none (sibling of t1335)
- **Conversation context:** Continuation of the post-supervisor-replacement audit. After archiving Tier 1 (pulse-duplicated scripts), these Tier 2 scripts are over-engineered bash implementations of things that `/full-loop` workers and AI already handle better. They represent ~9,500 lines of deterministic retry loops, quality normalization layers, and parallel orchestrators that AI renders unnecessary.

## What

Archive 8 scripts (~9,582 lines) to `.agents/scripts/archived/` that are over-engineered for what they do. These are bash implementations of capabilities that `/full-loop` workers handle end-to-end, or normalization layers that AI doesn't need because it understands all quality tool output formats natively.

**Scripts to archive:**

| Script | Lines | Why redundant |
|--------|-------|--------------|
| `quality-loop-helper.sh` | 1,191 | Full-loop preflight already runs linters iteratively. AI reads output and fixes intelligently vs bash mechanical retry. |
| `quality-sweep-helper.sh` | 1,714 | Fetches/normalizes findings from SonarCloud/Codacy/CodeFactor/CodeRabbit into SQLite. AI reads these tools' output directly via `gh` API — normalization layer unnecessary. |
| `review-pulse-helper.sh` | 743 | Daily full codebase AI review. The pulse already dispatches workers for PR reviews. Separate review pulse is redundant. |
| `coderabbit-pulse-helper.sh` | 513 | Triggers CodeRabbit full codebase review. CodeRabbit runs automatically on PRs via GitHub Actions. Manual trigger script unnecessary. |
| `coderabbit-task-creator-helper.sh` | 1,628 | Creates tasks from CodeRabbit findings. AI can read CodeRabbit PR comments and create better-scoped tasks with context. |
| `audit-task-creator-helper.sh` | 1,628 | Identical to coderabbit-task-creator (literally same content). Duplicate file. |
| `objective-runner-helper.sh` | 1,334 | Long-running objective execution with budget/step limits. This is what `/full-loop` does. The "safety guardrails" are deterministic gates that override AI decisions — the exact problem the pulse replacement solved. |
| `ralph-loop-helper.sh` | 831 | Cross-tool iterative AI development loop. Another loop orchestrator. `/full-loop` already handles the complete lifecycle. |

**SQLite databases to remove (runtime only):**
- Any `quality-sweep*.db`, `findings*.db` files in `.agent-workspace/`
- These contain derived data from quality tools — the tools themselves (SonarCloud dashboard, Codacy dashboard, CodeRabbit PR comments) are the primary source.

## Why

- **AI understands all formats natively:** The quality-sweep-helper exists to normalize SonarCloud JSON, Codacy JSON, CodeFactor JSON, and CodeRabbit markdown into a common SQLite schema. AI reads all these formats without normalization. The entire 1,714-line script is a translation layer that AI doesn't need.
- **Duplicate orchestrators:** `objective-runner-helper.sh`, `ralph-loop-helper.sh`, and `quality-loop-helper.sh` are all variations of "run thing → check result → retry". `/full-loop` already does this with AI judgment instead of fixed retry counts.
- **Duplicate files:** `audit-task-creator-helper.sh` and `coderabbit-task-creator-helper.sh` are literally identical (1,628 lines each). One is a copy of the other.
- **Zero external references:** Confirmed via `rg` — none of these scripts are called by any active code outside themselves.
- **Maintenance cost:** 9,582 lines of bash that nobody calls, with SQLite schemas that diverge from GitHub state.

## How (Approach)

1. **Verify t1335 completed successfully:** Tier 1 archive should be done first to validate the pattern.
2. **Verify zero callers:** `rg -l "<script-name>" .agents/ --include '*.md' --include '*.sh' | grep -v archived` for each. Already confirmed zero for all 8.
3. **Move scripts:** `git mv .agents/scripts/<script>.sh .agents/scripts/archived/` for each.
4. **Check for companion files:** Some scripts may have associated test files, config files, or `.md` docs. Search with `rg` and archive those too.
5. **Clean shared-constants.sh:** Remove any constants exclusively used by these scripts.
6. **Remove runtime SQLite DBs:** Document which `.db` files in `~/.aidevops/.agent-workspace/` are safe to delete.
7. **Verify full-loop still works:** Run a `/full-loop` on a small task to confirm the preflight quality checks still work without `quality-loop-helper.sh` (they should — full-loop calls `linters-local.sh` directly, not quality-loop-helper).
8. **Verify CodeRabbit still runs:** Confirm CodeRabbit GitHub Action still triggers on PRs without the pulse helper.

## Acceptance Criteria

- [ ] All 8 scripts moved to `.agents/scripts/archived/`
  ```yaml
  verify:
    method: bash
    run: "ls .agents/scripts/archived/quality-loop-helper.sh .agents/scripts/archived/quality-sweep-helper.sh .agents/scripts/archived/review-pulse-helper.sh .agents/scripts/archived/coderabbit-pulse-helper.sh .agents/scripts/archived/coderabbit-task-creator-helper.sh .agents/scripts/archived/audit-task-creator-helper.sh .agents/scripts/archived/objective-runner-helper.sh .agents/scripts/archived/ralph-loop-helper.sh 2>/dev/null | wc -l | grep -q '^8$'"
  ```
- [ ] Zero references to archived scripts from active code
  ```yaml
  verify:
    method: bash
    run: "rg -l 'quality-loop-helper|quality-sweep-helper|review-pulse-helper|coderabbit-pulse-helper|coderabbit-task-creator-helper|audit-task-creator-helper|objective-runner-helper|ralph-loop-helper' .agents/ --include '*.md' --include '*.sh' 2>/dev/null | grep -v archived | wc -l | grep -q '^0$'"
  ```
- [ ] `/full-loop` preflight quality checks still work (run on a test task)
  ```yaml
  verify:
    method: manual
    prompt: "Dispatch a small test worker and verify it passes preflight (linters-local.sh runs, markdown lint passes)."
  ```
- [ ] CodeRabbit still triggers automatically on new PRs
  ```yaml
  verify:
    method: manual
    prompt: "Check that the PR created by this task gets a CodeRabbit review comment automatically."
  ```
- [ ] No orphaned SQLite databases remain in .agent-workspace that reference archived scripts
  ```yaml
  verify:
    method: bash
    run: "fd -e db ~/.aidevops/.agent-workspace/ 2>/dev/null | grep -iE 'quality|finding|sweep' | wc -l | grep -q '^0$'"
  ```
- [ ] Markdown lint clean on all modified .md files

## Context & Decisions

- **Why archive after t1335:** Tier 1 scripts are clearly redundant (pulse does exactly what they did). Tier 2 scripts are over-engineered but not direct duplicates — they do things that AI handles implicitly. Archiving Tier 1 first validates the pattern and proves the system works without bash orchestration.
- **quality-loop-helper vs linters-local.sh:** `linters-local.sh` is the actual linter runner (kept). `quality-loop-helper.sh` is a wrapper that retries linters in a loop — the retry logic is what's redundant, not the linting itself.
- **CodeRabbit runs via GitHub Actions:** The `coderabbit-pulse-helper.sh` was a manual trigger for full-repo reviews. CodeRabbit's GitHub App already reviews every PR automatically. The manual trigger added no value.
- **No data migration:** Quality sweep SQLite data is derived from tool dashboards (SonarCloud, Codacy, etc.) which remain accessible. The DB is not primary-source information.

## Relevant Files

- `.agents/scripts/quality-loop-helper.sh` — 1,191 lines
- `.agents/scripts/quality-sweep-helper.sh` — 1,714 lines
- `.agents/scripts/review-pulse-helper.sh` — 743 lines
- `.agents/scripts/coderabbit-pulse-helper.sh` — 513 lines
- `.agents/scripts/coderabbit-task-creator-helper.sh` — 1,628 lines
- `.agents/scripts/audit-task-creator-helper.sh` — 1,628 lines (duplicate of above)
- `.agents/scripts/objective-runner-helper.sh` — 1,334 lines
- `.agents/scripts/ralph-loop-helper.sh` — 831 lines
- `.agents/scripts/linters-local.sh` — the actual linter runner (KEEP — not redundant)
- `.agents/scripts/commands/full-loop.md` — references preflight quality checks

## Dependencies

- **Blocked by:** t1335 (Tier 1 archive — validates the pattern)
- **Blocks:** t1337 (Tier 3 simplification)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Verify zero callers, check companion files |
| Implementation | 30m | git mv, clean constants, remove runtime DBs |
| Testing | 45m | Run /full-loop test task, verify CodeRabbit, verify pulse |
| **Total** | **~1.5h** | |
