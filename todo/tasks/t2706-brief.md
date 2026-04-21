<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2706: redeploy on .deployed-sha drift, not just VERSION/sentinel

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `deployed-sha drift redeploy` → 1 hit — diagnostic memory `mem_20260421190735_390b100f` (this session's root-cause)
- [x] Discovery pass: `git log --since="24h" -- aidevops.sh .agents/scripts/auto-update-helper.sh` → no in-flight overlapping commits; `gh pr list --search "deployed-sha"` → none open/merged recently
- [x] File refs verified: `aidevops.sh:550-560`, `.agents/scripts/auto-update-helper.sh:1326-1340`, `setup-modules/agent-deploy.sh:612`, `.agents/scripts/aidevops-update-check.sh:553-615` all present at HEAD
- [x] Tier: `tier:standard` — two files, inline stamp-check, regression test, all diff blocks exact, but spans two scripts and adds integration-level test harness; exceeds `tier:simple` acceptance-criteria cap (5 > 4)

## Origin

- **Created:** 2026-04-21
- **Session:** claude-code:interactive (opus-4-7)
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none
- **Conversation context:** Root-cause investigation of why `~/.aidevops/.deployed-sha` lagged `origin/main` by 6 commits for ~14h while the auto-updater was firing every 10min. The headRefName fix (PR #20323, t2695) merged to main at ~05:40 UTC but the pulse kept crashing in batch-prefetch because the deployed copy of `pulse-batch-prefetch-helper.sh` still had the pre-fix code. Two blind spots diagnosed in the headless redeploy paths; this PR fixes both. Companion to t2156 (detector side shipped in PR #19462).

## What

Make `aidevops update` self-heal deployed-script drift on EVERY merge to main — not just on version bumps or changes to one sentinel file. Two changes:

1. `aidevops.sh::cmd_update` — when the git repo is already up-to-date (`local_hash == remote_hash`), after the existing VERSION-file comparison, also compare `~/.aidevops/.deployed-sha` against `$local_hash`. If drifted AND the drift includes framework code paths, run `setup.sh --non-interactive`.
2. `.agents/scripts/auto-update-helper.sh::_cmd_check_stale_agent_redeploy` — replace the single-sentinel SHA-256 check with the same `.deployed-sha` stamp check, filtered to framework code paths.

Both checks skip docs-only drift (no need to redeploy for README/TODO/comment changes).

## Why

Observed 2026-04-21: `~/.aidevops/.deployed-sha` lagged `origin/main` by 6 commits for ~14h, including PR #20323 (t2695) which fixed `gh search prs --headRefName` — a bug crashing the pulse batch prefetch every ~4 minutes. The auto-updater runs every 10min but two blind spots prevented redeployment:

1. **`aidevops.sh::cmd_update`** (line 550-560) — when `local_hash == remote_hash` (git already up to date), only compares `VERSION` files. `VERSION` bumps on releases only, so inter-release merges never trigger `setup.sh --non-interactive`.
2. **`auto-update-helper.sh::_cmd_check_stale_agent_redeploy`** (line 1326-1340) — compares SHA-256 of a single sentinel file (`gh-failure-miner-helper.sh`). If the merged fix touches a different file (like `pulse-batch-prefetch-helper.sh`), drift is invisible.

`.deployed-sha` IS written correctly by `setup-modules/agent-deploy.sh:612`. `_check_script_drift` in `aidevops-update-check.sh` already does the right check — but it only fires on interactive session start via `_run_session_advisories`, not from headless auto-update paths.

This PR completes the loop that t2156 (PR #19462) started: detector shipped, stamp written, but the two headless redeploy entry points were not wired to consult the stamp. Every time an inter-release merge happens, the framework should converge within one auto-update cycle — not wait for the next VERSION bump.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** 2 production files + 1 new test file = 3 total (borderline)
- [x] **Every target file under 500 lines?** `aidevops.sh` is 2000+ lines (FAIL)
- [x] **Exact `oldString`/`newString` for every edit?** Yes — both changes use verbatim blocks, but `aidevops.sh` edit adds a new `else` branch rather than replacing existing code
- [x] **No judgment or design decisions?** Low-judgment: one decision already made (filter to framework paths vs redeploy on any change) per t2156 precedent
- [x] **No error handling or fallback logic to design?** Minor: `git diff` with `HEAD...stamp` where stamp could be missing or unknown — handled via `|| true` + `git cat-file -e`
- [x] **No cross-package or cross-module changes?** Two scripts in the same framework tree (aidevops.sh + auto-update-helper.sh)
- [x] **Estimate 1h or less?** ~1h including test
- [x] **4 or fewer acceptance criteria?** 5 criteria (exceeds cap)

Two FAIL flags (`aidevops.sh` >500 lines, 5 acceptance criteria), plus scope across two scripts → `tier:standard`. A `tier:simple` worker could plausibly complete this, but the pulse's tier validator would downgrade it — so we declare `tier:standard` upfront.

**Selected tier:** `tier:standard`

## PR Conventions

Leaf (non-parent) issue — PR body uses `Resolves #20341` as normal.

## How (Approach)

### Files to Modify

- `EDIT: aidevops.sh` — in `cmd_update`, inside the `local_hash == remote_hash` branch, extend the existing VERSION-mismatch check with a `.deployed-sha` drift check. Model on the structure of `aidevops-update-check.sh::_check_script_drift`.
- `EDIT: .agents/scripts/auto-update-helper.sh` — in `_cmd_check_stale_agent_redeploy`, replace the single-sentinel SHA-256 block with the `.deployed-sha` stamp check filtered to framework code paths.
- `NEW: .agents/scripts/tests/test-cmd-update-sha-drift.sh` — regression harness with 9 assertions: 5 structural (markers present, filter correct, sentinel removed, VERSION check preserved, function signatures intact) + 4 sandbox integration (no stamp → skip, stamp==HEAD → skip, code drift → fire, docs-only drift → skip).

### Implementation Steps

1. **`aidevops.sh` edit** — in `cmd_update`, inside the `if [[ "$local_hash" == "$remote_hash" ]]` branch, after the VERSION check, add an `else` branch that reads `$AIDEVOPS_STATE_DIR/.deployed-sha`, short-circuits if missing or equal to `$local_hash`, computes `git diff --name-only $deployed_sha...$local_hash` filtered to `.agents/`, `setup.sh`, `setup-modules/`, `aidevops.sh`, and — if any file matches — runs `setup.sh --non-interactive` with a `[WARN] Deployed scripts drifted (<short>→<short>)` log line.

2. **`auto-update-helper.sh` edit** — in `_cmd_check_stale_agent_redeploy`, delete the `gh-failure-miner-helper.sh` sentinel SHA-256 block and replace with the same `.deployed-sha` check. Keep the VERSION comparison as the first gate. Emit the same `[WARN]` line on drift so pulse telemetry is consistent with interactive-session advisory wording.

3. **Regression test** — model on `test-script-drift-detection.sh` (244 lines). Sandbox harness creates a temp `AIDEVOPS_STATE_DIR` with a controllable `.deployed-sha`, invokes `cmd_update --skip-project-sync` with mocked git, asserts on stdout markers plus stamp file mutations.

### Verification

```bash
# Structural checks (no external deps)
shellcheck aidevops.sh .agents/scripts/auto-update-helper.sh .agents/scripts/tests/test-cmd-update-sha-drift.sh

# Regression test
bash .agents/scripts/tests/test-cmd-update-sha-drift.sh

# Live end-to-end: stale the stamp, confirm redeploy fires
printf 'ca91b761cfb5183af0000000000000000000abcd\n' > ~/.aidevops/.deployed-sha
bash aidevops.sh update --skip-project-sync 2>&1 | grep -E '(Deployed scripts drifted|Re-running setup)'
cat ~/.aidevops/.deployed-sha  # should equal `git rev-parse origin/main`

# Docs-only skip: stale to a commit that only touched TODO.md/*.md
# (Confirm no '[INFO] Re-running setup' line appears.)
```

### Files Scope

- aidevops.sh
- .agents/scripts/auto-update-helper.sh
- .agents/scripts/tests/test-cmd-update-sha-drift.sh
- TODO.md
- todo/tasks/t2706-brief.md

## Acceptance Criteria

- [ ] Staling `.deployed-sha` to a prior SHA with framework-code drift and running `aidevops update --skip-project-sync` emits `[WARN] Deployed scripts drifted` AND `[INFO] Re-running setup` AND advances the stamp to HEAD.

  ```yaml
  verify:
    method: bash
    run: "cd ~/Git/aidevops && printf '007fd3558\n' > ~/.aidevops/.deployed-sha && bash aidevops.sh update --skip-project-sync 2>&1 | grep -q 'Deployed scripts drifted'"
  ```

- [ ] Staling `.deployed-sha` to a commit where the only diff vs HEAD is `*.md` files DOES NOT trigger `Re-running setup`.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/tests/test-cmd-update-sha-drift.sh 2>&1 | grep -qE '^PASS.*docs-only skip'"
  ```

- [ ] Existing VERSION-mismatch redeploy path continues to work (regression test covers).

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/tests/test-cmd-update-sha-drift.sh 2>&1 | grep -qE 'VERSION check preserved'"
  ```

- [ ] `gh-failure-miner-helper.sh` sentinel SHA-256 block is removed from `_cmd_check_stale_agent_redeploy`.

  ```yaml
  verify:
    method: codebase
    pattern: 'gh-failure-miner-helper'
    path: '.agents/scripts/auto-update-helper.sh'
    expect: absent
  ```

- [ ] New regression test `test-cmd-update-sha-drift.sh` passes cleanly (9/9 assertions).

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-cmd-update-sha-drift.sh 2>&1 | tail -1 | grep -q 'PASS 9/9'"
  ```

## Context & Decisions

- **Why inline, not a new `check-drift` subcommand:** Delegating to a subcommand of `aidevops-update-check.sh` would create a bootstrap chicken-and-egg — the redeploy path needs to run BEFORE the latest version of `aidevops-update-check.sh` is deployed. Inlining the logic in each caller means the check works even when the deployed copy is the stale one that needs to be replaced.
- **Why framework code paths only (filter):** Matches the t2156 precedent in `_check_script_drift`. Docs-only churn (README, TODO.md, comments) happens 10-20× a day via chore: claim commits and planning pushes. Redeploying on every one of those would thrash `setup.sh` unnecessarily.
- **Why `git diff --name-only` not `git log --name-only`:** Diff is a single range query (O(1) git-internal), whereas log-with-name-only re-walks the revision graph per call. For a 20-commit drift window the difference is ~20× CPU.
- **Rejected alternative — a single sentinel file per subsystem:** Still misses drift in other subsystems. The sentinel pattern inherently cannot scale to "any framework file". Stamp comparison is the correct structure.
- **Rejected alternative — redeploy on every `local_hash == remote_hash` cycle regardless of stamp:** Would thrash `setup.sh --non-interactive` every 10min even when nothing changed. The stamp is the idempotency key.
- **Not goals:** Changing the stamp format, touching `setup-modules/agent-deploy.sh`, altering the auto-updater launchd plist cadence, fixing the GraphQL exhaustion that made this session use REST fallback for issue creation.

## Relevant Files

- `aidevops.sh:540-580` — `cmd_update` branch where the new check lives
- `.agents/scripts/auto-update-helper.sh:1320-1345` — `_cmd_check_stale_agent_redeploy` sentinel block being replaced
- `setup-modules/agent-deploy.sh:612` — the stamp writer (unchanged, just referenced)
- `.agents/scripts/aidevops-update-check.sh:553-615` — `_check_script_drift` model pattern (unchanged)
- `.agents/scripts/tests/test-script-drift-detection.sh` — sibling regression test to mirror structure from
- `~/Library/LaunchAgents/com.aidevops.aidevops-auto-update.plist` — StartInterval 600s launchd that invokes the updated code path (unchanged)

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing critical. Future work on `aidevops security check` advisories could consume this signal more broadly.
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read (done in-session) | ~20m | Diagnosis + memory write completed before claim |
| Implementation | ~25m | Both edits + test harness |
| Live verification | ~10m | Stale stamp + re-run + confirm advance |
| PR ceremony | ~10m | Rebase, commit, push, PR body |
| **Total** | **~1h** | |
