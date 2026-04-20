<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2432: add recent-commit sweep to pre-dispatch eligibility gate

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pre-dispatch eligibility gate recent-commit` — 1 hit — prior t2424 session lessons (stale worktree / positional-param refactor / function-complexity extraction / admin-merge fallback); no existing lesson on the recent-commit sweep specifically.
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch `pre-dispatch-eligibility-helper.sh` in last 48h other than the just-merged PR #20064 (t2424).
- [x] File refs verified: 3 refs checked, all present at HEAD of merged main (`pre-dispatch-eligibility-helper.sh:is_issue_eligible_for_dispatch`, `tests/test-pre-dispatch-eligibility.sh`, `pulse-dispatch-core.sh::_run_eligibility_gate_or_abort`).
- [x] Tier: `tier:standard` — target file 239 lines (<500), edits cross 2 files, but includes a judgment call on window-size tuning and a new exit-code contract. Not tier:simple.

## Origin

- **Created:** 2026-04-20
- **Session:** Claude Code CLI:t2424-followup
- **Created by:** ai-interactive (Claude, opus-4-7)
- **Parent task:** t2424 (closed — GH#20030, PR #20064 merged)
- **Conversation context:** During the t2424 full-loop (pre-dispatch eligibility gate: 3 checks — CLOSED state, `status:done|resolved` label, linked PR merged within 5 min), the user surfaced a fourth heuristic — scan recent commits on the default branch for messages referencing the issue number — and asked whether to include it. We agreed to defer it: the 3 existing checks cover the observed no_work churn pattern (stale prefetch cache after pulse-merge); the 4th check adds cost (git log / gh api per candidate issue) and a new false-positive surface (commit references on unrelated branches, `Ref #NNN` / `For #NNN` planning commits). Better to deploy the 3-check gate, observe, and only add the 4th if the telemetry justifies it.

## What

Add a fourth eligibility check to `is_issue_eligible_for_dispatch()` in `.agents/scripts/pre-dispatch-eligibility-helper.sh`. The new check scans commits on the repository's default branch (typically `main`) from the last ~10 minutes and aborts dispatch if any commit message contains a closing keyword + this issue's number (e.g., `Fixes #NNN`, `Closes #NNN`, `Resolves #NNN`). This closes a gap where a direct-to-main commit (planning allowlist path: `TODO.md`, `todo/**`, `README.md` changes from headless workers) resolves an issue without going through a PR, and the pulse's prefetch cache still sees the issue as open for a few minutes.

Deliverables:

1. New exit code `5 — recent-commit on default branch` in `pre-dispatch-eligibility-helper.sh`.
2. Fourth check in `is_issue_eligible_for_dispatch()`, implemented as a new helper `_check_recent_commit_closes_issue <issue_num> <repo_slug>` for symmetry with the existing three checks.
3. Stats counter `pre_dispatch_aborts_recent_commit` in `pulse-stats-helper.sh` and surfaced in `aidevops status` output.
4. Test coverage in `test-pre-dispatch-eligibility.sh`: `test_recent_commit_closes_issue_blocks_dispatch` (happy path) and `test_recent_commit_different_issue_allows_dispatch` (negative / isolation).
5. Env override `AIDEVOPS_PREDISPATCH_RECENT_COMMIT_WINDOW=<seconds>` (default 600) mirroring the existing `AIDEVOPS_PREDISPATCH_RECENT_MERGE_WINDOW` pattern.

## Why

**Do not implement until the trigger condition fires.** This task is gated on observation from the deployed 3-check gate.

**Trigger condition (implement only if true):**

```bash
# Run whenever investigating pulse churn — no schedule, no deadline:
grep -c "no_work skip-escalation" ~/.aidevops/logs/pulse-wrapper.log \
  | awk '{ if ($1 >= 1) print "TRIGGER: " $1 " events observed — implementation justified"; else print "Below threshold: " $1 " events — leave in backlog" }'
```

**Trigger semantics:** observed ≥1 `no_work skip-escalation` events in the pulse log since the 3-check gate deployed. Measured whenever the maintainer chooses to check — there is no deadline, no expiry, and no auto-close. If the rate stays low, the issue sits in backlog indefinitely. The issue only closes on explicit maintainer decision (e.g., the 3-check gate's churn profile is acceptable as-is, or the underlying churn pattern has been addressed differently). Project attention is variable; absence of observation is not evidence the task is unwanted.

**Why the 3-check gate may be sufficient:**

- The observed no_work churn pattern is "PR just merged, prefetch cache stale, pulse picks up the now-resolved issue". Check 3 (linked PR merged in last 5 min) catches this exact case because `gh issue view --json closedByPullRequestsReferences` returns the PR even before GitHub propagates the issue's `closed` state fully.
- Direct-to-main planning commits that close issues (TODO.md edits with `Fixes #NNN`) are rare. They mostly happen from headless workers via `issue-sync.yml` which closes the issue server-side before the pulse can see it.

**Why a 4th check adds cost:**

- One extra `git log` or `gh api commits` call per candidate issue (the gate runs in the hot path of `dispatch_with_dedup`).
- New false-positive surface: `Ref #NNN` / `For #NNN` commits are planning-only references, not closes. The regex must be precise (`(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#NNN` — same as `pulse-merge.sh::_extract_linked_issue`). Any looser match produces false aborts.
- Commits on non-default branches must be excluded (a WIP commit on a feature branch that says `Fixes #NNN` does not resolve the issue until its PR merges).

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** 2 files: `pre-dispatch-eligibility-helper.sh`, `test-pre-dispatch-eligibility.sh`. (Plus a stats key in `pulse-stats-helper.sh` — borderline 3rd file.)
- [x] **Every target file under 500 lines?** 239 / 344 / 237 — all under.
- [ ] **Exact `oldString`/`newString` for every edit?** No — the new `_check_recent_commit_closes_issue` helper must be designed against the existing helper pattern. Exact block cannot be pre-written without resolving the git log vs gh api call decision.
- [ ] **No judgment or design decisions?** No — choice of `git log` (faster, but requires fetch) vs `gh api commits` (authoritative, but network round-trip) is a judgment call. Exit code `5` assignment also requires verifying no collision with other helpers.
- [x] **No error handling or fallback logic to design?** Yes — pattern is "fail-open on error, log a warning" identical to the existing helpers.
- [x] **No cross-package or cross-module changes?** Correct — all changes within `.agents/scripts/`.
- [x] **Estimate 1h or less?** ~45min estimated (see breakdown).
- [ ] **4 or fewer acceptance criteria?** 6 criteria below.

All checked = `tier:simple`. Any unchecked = `tier:standard` (default) or `tier:thinking`.

**Selected tier:** `tier:standard`

**Tier rationale:** Three disqualifiers checked "no": the git log vs gh api design choice is a real judgment call, exit code assignment needs verification against the existing contract, and the regex precision is a known-risk area from t2204 (markdown-doesn't-shield-keywords). Sonnet is appropriate — the pattern exists (3 sibling checks), but the worker needs to match tone and handle the edge cases, not just transcribe.

## PR Conventions

Leaf task (not a parent-task). PR body uses `Resolves #<this-issue>` as normal. No `For`/`Ref` rule applies.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pre-dispatch-eligibility-helper.sh:5-30` — add exit code 5 to the header comment table.
- `EDIT: .agents/scripts/pre-dispatch-eligibility-helper.sh:~165-210` — add `_check_recent_commit_closes_issue()` helper after the existing third check, and an invocation from `is_issue_eligible_for_dispatch()`.
- `EDIT: .agents/scripts/pulse-stats-helper.sh` — add `pre_dispatch_aborts_recent_commit` counter field.
- `EDIT: .agents/scripts/tests/test-pre-dispatch-eligibility.sh` — add two new `test_recent_commit_*` cases following the existing test pattern.

### Implementation Steps

1. **Read the three existing checks** in `pre-dispatch-eligibility-helper.sh` (`_check_closed_state`, `_check_done_label`, `_check_recent_merge`) to match their signature, error handling, and return convention. Model the new helper exactly on `_check_recent_merge` — it's the closest pattern (also time-windowed, also uses `gh api`).

2. **Decide git log vs gh api for commit scanning:**
   - `gh api repos/{slug}/commits?sha={default_branch}&since={ISO-8601-10min-ago}` — authoritative, survives shallow clones, always sees latest pushed state. Network cost: 1 round-trip per issue (but same as the merge check).
   - `git log --since="10 minutes ago" origin/main --pretty=format:"%s"` — zero network, requires `git fetch` first (which the pulse does periodically). Risk: stale fetch → miss commits.
   - **Recommendation:** use `gh api commits` for parity with `_check_recent_merge`. The cost is already paid (we're already talking to GitHub for the merge check).

3. **Regex precision (critical):** use the exact extraction pattern from `pulse-merge.sh::_extract_linked_issue` — `grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#[0-9]+'`. Reject `Ref #NNN` and `For #NNN` (planning references, not closes). Test both cases.

4. **Exit code 5 placement:** update the header comment table (lines 5-30 of `pre-dispatch-eligibility-helper.sh`) and the `case` in the calling site in `pulse-dispatch-core.sh::_run_eligibility_gate_or_abort` if present (verify — may not need a case branch if existing code handles all non-zero uniformly; audit `_run_eligibility_gate_or_abort` at `.agents/scripts/pulse-dispatch-core.sh`).

5. **Stats counter:** add `pre_dispatch_aborts_recent_commit` as a sibling to the existing `pre_dispatch_aborts_*` keys in `pulse-stats-helper.sh`. Surface in `aidevops.sh::cmd_status` output.

6. **Tests** (in `test-pre-dispatch-eligibility.sh`):
   - `test_recent_commit_closes_issue_blocks_dispatch`: mock a commit with `Fixes #42` on main within the last 5 min; call gate with issue 42; expect exit 5.
   - `test_recent_commit_different_issue_allows_dispatch`: mock a commit with `Fixes #99`; call gate with issue 42; expect exit 0 (gate passes).
   - `test_recent_commit_ref_keyword_allows_dispatch`: mock a commit with `Ref #42` (planning reference); call gate with issue 42; expect exit 0 (not a close).
   - Follow the existing mock pattern — functions stub `gh api` responses via `GH_MOCK_RESPONSE` or similar (audit current mocking strategy in the test file).

### Verification

```bash
# Shellcheck clean
shellcheck .agents/scripts/pre-dispatch-eligibility-helper.sh \
  .agents/scripts/pulse-stats-helper.sh \
  .agents/scripts/tests/test-pre-dispatch-eligibility.sh

# All tests pass
bash .agents/scripts/tests/test-pre-dispatch-eligibility.sh

# aidevops status surfaces the new counter
aidevops status | grep -q "pre_dispatch_aborts_recent_commit"
```

## Acceptance Criteria

- [ ] `is_issue_eligible_for_dispatch()` returns exit code 5 when a commit on the default branch within `AIDEVOPS_PREDISPATCH_RECENT_COMMIT_WINDOW` seconds contains a valid closing keyword referencing the candidate issue number.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pre-dispatch-eligibility.sh"
  ```
- [ ] `Ref #NNN` and `For #NNN` planning-reference commits do NOT trigger the new check (regex precision matches `pulse-merge.sh::_extract_linked_issue`).
  ```yaml
  verify:
    method: codebase
    pattern: "close\\[ds\\]\\?\\|fix\\(es\\|ed\\)\\?\\|resolve\\[ds\\]\\?"
    path: ".agents/scripts/pre-dispatch-eligibility-helper.sh"
  ```
- [ ] `pre_dispatch_aborts_recent_commit` counter increments when the new check fires and is surfaced in `aidevops status`.
  ```yaml
  verify:
    method: codebase
    pattern: "pre_dispatch_aborts_recent_commit"
    path: ".agents/scripts/pulse-stats-helper.sh .agents/aidevops.sh"
  ```
- [ ] New test cases cover both the happy path and the `Ref/For` negative case.
  ```yaml
  verify:
    method: codebase
    pattern: "test_recent_commit_.*"
    path: ".agents/scripts/tests/test-pre-dispatch-eligibility.sh"
  ```
- [ ] Fail-open on `gh api` errors (network failure, auth expired) — the gate logs a warning and allows dispatch to proceed, matching the existing helpers' pattern.
  ```yaml
  verify:
    method: manual
    prompt: "Review the new helper's error handling — it must return 0 (allow) on gh api failure, identical to _check_recent_merge."
  ```
- [ ] Tests pass (`bash .agents/scripts/tests/test-pre-dispatch-eligibility.sh`) and shellcheck is clean on all three edited scripts.

## Context & Decisions

**Why defer rather than implement now:**

- The 3-check gate deployed in PR #20064 (t2424) addresses the observed churn pattern: stale prefetch cache after `pulse-merge.sh` auto-closes an issue. Check 3 (linked PR merged in last 5 min) catches this directly.
- Implementing the 4th check adds cost (one extra `gh api` call per candidate issue in the dispatch hot path) and a new false-positive surface (regex precision against `Ref`/`For` planning references).
- The right time to add it is when telemetry shows the 3-check gate is insufficient — i.e., `no_work skip-escalation` events are occurring at ≥1/week AFTER the 3-check gate is deployed. Deploying first, measuring second, extending only if justified is the cheaper path.

**Why `origin:interactive` + no `auto-dispatch`:**

- This is a conditional-trigger backlog item. The pulse must NOT dispatch a worker against it until a maintainer confirms the trigger condition is met and manually applies `auto-dispatch`.
- `origin:interactive` + self-assignment blocks pulse dispatch permanently per GH#18352/t1996 dedup guard. The maintainer owns the decision to release it.

**Non-goals / explicitly ruled out:**

- Scanning commits on non-default branches (feature branches may have unmerged WIP commits referencing the issue — these do NOT resolve it).
- Extending the window beyond ~10 minutes (the existing recent-merge window is 5 min; a 10-min window for commits is already generous).
- Adding a commit-message check to the PR merge path (that already exists in `pulse-merge.sh::_extract_linked_issue` — we're replicating the same regex in a different context).

## Relevant Files

- `.agents/scripts/pre-dispatch-eligibility-helper.sh:1-239` — canonical file; lines 5-30 (header comment), `_check_recent_merge` helper (~lines 130-165) is the closest model for the new check.
- `.agents/scripts/pulse-dispatch-core.sh::_run_eligibility_gate_or_abort` — layer 6 caller; verify exit code 5 is handled or falls through to a generic abort.
- `.agents/scripts/pulse-stats-helper.sh` — stats plumbing.
- `.agents/scripts/tests/test-pre-dispatch-eligibility.sh:1-344` — existing test pattern; mock strategy and helper invocation pattern to match.
- `.agents/scripts/pulse-merge.sh::_extract_linked_issue` — canonical closing-keyword regex. Copy, don't reinvent.
- `.agents/AGENTS.md` "Pre-dispatch eligibility gate" paragraph — update on landing to list 4 checks instead of 3.

## Dependencies

- **Blocked by:** Trigger condition — ≥1 `no_work skip-escalation` event/week rolling 4-week window after PR #20064 deploys.
- **Blocks:** Nothing directly. The 3-check gate deployed in t2424 is sufficient until the trigger fires.
- **External:** None. Implementation is self-contained within `.agents/scripts/`.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Read 3 existing checks in `pre-dispatch-eligibility-helper.sh`, `_extract_linked_issue` in `pulse-merge.sh`, existing test mock pattern |
| Implementation | 20m | New helper, integration into `is_issue_eligible_for_dispatch`, stats counter, exit-code plumbing |
| Testing | 15m | 3 new test cases, run full test suite, shellcheck |
| **Total** | **45m** | |
