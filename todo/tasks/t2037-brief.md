---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2037: refactor(maintainer-gate): delete Job 3 inline gate logic, delegate authoritative state to Job 1

## Origin

- **Created:** 2026-04-13
- **Session:** OpenCode:interactive (gap-closing pass that shipped t2015/t2018/t2027–t2030/t2034)
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none
- **Conversation context:** During the gap-closing session I shipped t2018 (Job 3 reruns Job 1 for required CheckRun refresh) and t2030 (Check -1 moved out of the empty-linked-issues branch). Both were narrow surgical fixes against a deeper structural issue: **Job 3 of `.github/workflows/maintainer-gate.yml` duplicates ~90 lines of Job 1's gate-evaluation logic inline.** When I shipped t2030 (Check -1 expansion) on Job 1, CodeRabbit independently flagged on the t2030 PR review that **Job 3 does not have the parallel `origin:interactive` exemption** — third-party confirmation that the duplication is already drifting in production code, not just theoretical risk. This task ships the underlying refactor: Job 3 stops evaluating gate state itself and becomes pure plumbing that delegates to Job 1 via the t2018 rerun mechanism.

## What

Job 3 (`retrigger-pr-checks`) in `.github/workflows/maintainer-gate.yml` no longer contains the inline `for ISSUE_NUM in $LINKED_ISSUES; do ... Check 1 ... Check 2 ... done` evaluation block. Instead, Job 3:

1. Finds linked PRs referencing the updated issue (current logic, kept).
2. For each PR: posts a `pending` `maintainer-gate` status context with description "Re-evaluating via Job 1 rerun…" so the dashboard reflects in-progress refresh.
3. Calls the t2018 `rerun-failed-jobs` block (current logic, kept) to trigger Job 1 to re-evaluate against current issue state.
4. Lets Job 1's run produce the authoritative `maintainer-gate` status context AND the `Maintainer Review & Assignee Gate` CheckRun.

Net effect: **Job 1 is the single source of truth for gate evaluation logic.** Adding/changing a gate rule means editing Job 1 only, not Job 1 + Job 3.

End-state: Job 3 shrinks from ~240 lines to ~80 lines. The inline evaluation (currently `maintainer-gate.yml:596-685` plus the post-final-status block) is deleted. Job 3's surface becomes: trigger conditions → find PRs → post pending status → trigger Job 1 rerun → done.

## Why

**Drift is now confirmed in production, not theoretical.** The session that shipped t2030 (Check -1 out of empty-linked-issues branch on Job 1) **did not** apply the same fix to Job 3, because Job 3 has its own copy of the gate logic and t2030 was scoped to Job 1. CodeRabbit's review on PR #18512 explicitly flagged this:

> Job 3 does not include the `origin:interactive` exemption that Job 1 now has. PRs that hit Job 3's evaluation path will still be blocked on linked-issue checks even when they should pass via the maintainer shortcut.

That's exactly the failure mode Job 1's t2030 fix was supposed to eliminate. The next maintainer-authored interactive PR that triggers Job 3 (e.g., when a label changes after PR creation) will get the OLD behaviour from Job 3 and the NEW behaviour from Job 1 — depending on which produces the visible signal first, the user sees inconsistent gate state.

**Why not just mirror t2030 into Job 3.** Mirroring fixes the immediate inconsistency but leaves the duplication in place. The next gate-rule change will hit the same problem. Eliminating Job 3's inline evaluation entirely solves the class of bug, not just the latest instance. CodeRabbit is unlikely to flag a fourth one if we close it now.

**Why this is a real cost, not just code smell.** Every time Job 1's gate logic changes — new exemption, new check, new edge case — there's an open question of whether to mirror it into Job 3. That question forces a maintainer code review every time. With the refactor, Job 1 is authoritative and the question disappears.

## Tier

### Tier checklist

- [x] **≤2 files to modify?** — 1 file: `.github/workflows/maintainer-gate.yml`
- [ ] **Complete code blocks for every edit?** — partial. The new Job 3 structure is described below in pseudocode, but the exact YAML formatting requires reading and adapting current line numbers at execution time (the file has changed since this brief was written).
- [ ] **No judgment or design decisions?** — moderate. Two judgment calls: (a) what does Job 3 post on the `maintainer-gate` status context while waiting for Job 1's rerun, (b) what to do if Job 1 has never run for the PR's HEAD SHA (degenerate edge case).
- [x] **No error handling or fallback logic to design?** — error paths reuse the t2018 fallback (warning + continue).
- [x] **≤1h estimate?** — 1-2h estimate.
- [x] **≤4 acceptance criteria?** — exactly 4

**Selected tier:** `tier:standard`

**Tier rationale:** This is medium-complexity refactoring of a security-critical workflow. The brief gives narrative direction with file references, but the executor needs to:
1. Re-read the current state of `maintainer-gate.yml` (line numbers will have drifted from t2018+t2030).
2. Decide how to compose the pending status context message.
3. Verify behaviour for two edge cases: PRs with no prior Job 1 run, and PRs where Job 1 was already success.
4. Run the workflow on a real PR before merging to confirm.

That's standard-tier work, not simple-tier copy-paste. Sonnet is the right model.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/maintainer-gate.yml` Job 3 (`retrigger-pr-checks`) — delete the inline gate-evaluation block (currently the for-loop over `LINKED_ISSUES` containing `Check 1` and `Check 2`), keep the find-PRs and rerun-failed-jobs blocks, replace the inline evaluation with a single pending-status post.

### Implementation Steps

**Step 1: Re-read the current Job 3 structure.**

```bash
git fetch origin main
sed -n '440,730p' .github/workflows/maintainer-gate.yml
```

Note the actual line numbers — t2018 + t2030 + future merges will have shifted them since this brief was written. The structural anchors that should still be present:

- `retrigger-pr-checks:` job header
- `Find linked PRs and re-evaluate gate` step
- `for PR_NUM in $OPEN_PRS; do` outer loop
- `for ISSUE_NUM in $LINKED_ISSUES; do` inner loop (this is what gets DELETED)
- `# Post final status` block
- `# t2018: refresh the REQUIRED CheckRun by re-running Job 1.` block

**Step 2: Identify what to delete.**

Delete the entire inner `for ISSUE_NUM in $LINKED_ISSUES; do ... done` loop AND the surrounding "BLOCKED=false / REASONS=" / "Post final status if BLOCKED" infrastructure that depends on it. That's roughly the block from "Get PR body and labels to find ALL linked issues" down to the closing `done` of the inner loop, plus the conditional post-final-status block that consumes `BLOCKED`.

Keep:

- The for-PR loop header and HEAD_SHA lookup
- The early "post pending status while we evaluate" block (lines ~516-522)
- The t2018 `rerun-failed-jobs` block
- The closing `done` of the outer for-PR loop

**Step 3: Replace the deleted block with a pending-status post.**

After the existing pending status post, insert a NEW post with a clearer message:

```bash
            # t2037: Job 3 no longer evaluates gate state itself. The
            # authoritative evaluation is in Job 1 (check-pr) which we
            # trigger via rerun-failed-jobs below. Post a pending status
            # so the dashboard shows the in-progress refresh; Job 1's
            # final post-status step will overwrite it on completion.
            gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
              --method POST \
              -f state=pending \
              -f context="maintainer-gate" \
              -f description="Refreshing via Job 1 rerun (issue #${ISSUE_NUMBER} updated)" \
              2>/dev/null || true
```

**Step 4: Verify the t2018 rerun block's edge cases.**

The t2018 block already handles two cases that matter post-refactor:

- **No prior Job 1 run for this HEAD SHA** (rare — implies the PR was opened during a window when Job 1 hadn't fired) → t2018 logs "No prior maintainer-gate run found" and skips. Job 3's pending status remains visible until the next pull_request event triggers Job 1 fresh. Acceptable degradation.
- **Latest Job 1 run was success** → t2018 short-circuits with "already succeeded — no refresh needed". The pending status Job 3 posted gets superseded by Job 1's existing success. Acceptable.
- **Latest Job 1 run was failure/cancelled** → t2018 calls rerun-failed-jobs. Job 1 reruns, re-reads issue state, posts fresh status. This is the happy path.

No new edge cases introduced by the refactor.

**Step 5: Visual diff check.**

```bash
git diff .github/workflows/maintainer-gate.yml | wc -l   # expect ~150-200 deleted lines
git diff .github/workflows/maintainer-gate.yml | grep -c "^-"   # most should be deletions
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/maintainer-gate.yml'))"
```

The job count for `maintainer-gate.yml` should still be the same (Job 3 still exists, just smaller). The required CheckRun name `Maintainer Review & Assignee Gate` is unchanged (it's Job 1's job name).

**Step 6: Runtime verification on a real PR.**

This refactor must be exercised end-to-end before merging. Suggested test:

1. Create a small dummy PR (e.g., a comment fix in a doc file) with `origin:interactive` and a linked issue that has `needs-maintainer-review` and no assignee.
2. Observe Job 1 fail with the gate.
3. Add the assignee or run `sudo aidevops approve`.
4. Observe Job 3 fire on the issue event.
5. Observe Job 3 post the pending `maintainer-gate` context.
6. Observe Job 3 trigger Job 1 rerun.
7. Observe Job 1 produce the new success CheckRun.
8. Observe the PR become mergeable.

If any step fails, the refactor is broken.

### Verification

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/maintainer-gate.yml'))" \
  && grep -c "for ISSUE_NUM in \$LINKED_ISSUES" .github/workflows/maintainer-gate.yml
# Expect 1 (only Job 1's loop should remain — Job 3's inner loop deleted)
```

## Acceptance Criteria

- [ ] Job 3 (`retrigger-pr-checks`) no longer contains a `for ISSUE_NUM in $LINKED_ISSUES; do ... done` loop. Only Job 1 has that loop.
  ```yaml
  verify:
    method: bash
    run: "test $(grep -c 'for ISSUE_NUM in \\$LINKED_ISSUES' .github/workflows/maintainer-gate.yml) -eq 1"
  ```
- [ ] Job 3 posts a `pending` `maintainer-gate` status context with description containing "Refreshing via Job 1 rerun" before triggering the rerun.
  ```yaml
  verify:
    method: codebase
    pattern: "Refreshing via Job 1 rerun"
    path: ".github/workflows/maintainer-gate.yml"
  ```
- [ ] The workflow file still parses as valid YAML.
  ```yaml
  verify:
    method: bash
    run: "python3 -c 'import yaml; yaml.safe_load(open(\".github/workflows/maintainer-gate.yml\"))'"
  ```
- [ ] Runtime: a real PR exercising the issue-update → Job 3 → rerun → Job 1 → fresh CheckRun → merge flow works end-to-end. (Verified via the test PR described in Step 6.)
  ```yaml
  verify:
    method: manual
    prompt: "Open a test PR with a linked needs-maintainer-review issue, trigger Job 3 via assignee/label change, and confirm Job 1 produces a fresh CheckRun within ~30 seconds without manual gh run rerun."
  ```

## Context & Decisions

**Why delete Job 3's inline evaluation entirely instead of mirroring t2030 into it.** Mirroring fixes the immediate Check -1 inconsistency but leaves the duplication structure in place. The next gate-rule change will face the same "do we mirror this?" question. Eliminating the duplication closes the class of bug.

**Why keep the `maintainer-gate` status context post in Job 3.** The status context is consumed by GitHub's PR UI status list. If Job 3 doesn't post anything visible while triggering the rerun, users see a momentary "no signal" state on the PR before Job 1's rerun completes. The pending status fills that ~10-15s gap with a clear "we're refreshing" message instead of stale state.

**Why not also delete Job 3's `find linked PRs` logic.** Job 3 still needs to know which PRs to refresh. The find-PRs path is data discovery, not gate evaluation. It stays.

**What about the `Re-evaluate PR Gate on Issue Change` job name.** Keep it. The job name is the CheckRun visible in the PR's checks list and any external dashboard or automation may reference it. Renaming to "Trigger Job 1 rerun on issue change" would be more accurate but breaks any consumer.

**Why this can't be tier:simple.** Writing a bash deletion is mechanical, but verifying that NO gate-relevant signal is lost requires reading the current Job 3 carefully, identifying every consumer of the deleted code, and checking the t2018 rerun edge cases. A simple-tier worker would risk deleting too much (breaking the find-PRs logic) or too little (leaving partial inline evaluation that conflicts with the rerun path).

**Non-goals:**

- Renaming the `Re-evaluate PR Gate on Issue Change` job (breaks external references).
- Changing Job 1's gate logic (out of scope — t2030 already handled the Check -1 case).
- Migrating to GitHub Rulesets (separate task — see t2038).
- Adding new gate conditions or exemption categories.
- Changing the `maintainer-gate` status context name.

## Relevant Files

- `.github/workflows/maintainer-gate.yml:444-730` — Job 3 (`retrigger-pr-checks`) as it currently stands post-t2018+t2030. Line numbers will have drifted by the time this task is dispatched — re-locate the structural anchors at execution time.
- `.github/workflows/maintainer-gate.yml:35-373` — Job 1 (`check-pr`) — the authoritative gate logic that Job 3 will delegate to.
- PR #18512 (t2030) — review thread where CodeRabbit flagged the missing Job 3 origin:interactive exemption.
- `todo/tasks/t2018-brief.md` — the rerun mechanism Job 3 already uses.
- `todo/tasks/t2030-brief.md` — the Check -1 fix that introduced the current drift.

## Dependencies

- **Blocked by:** none (t2018 + t2030 are both merged)
- **Blocks:** any future maintainer-gate.yml edit that adds a gate rule — until t2037 lands, the rule must be applied in two places.
- **External:** none. Branch protection config is not touched.

## Estimate Breakdown

| Phase | Time |
|-------|------|
| Re-read current Job 3 structure | 10m |
| Identify deletion + write replacement | 20m |
| YAML lint + visual diff review | 10m |
| Open PR, run /pr-loop, monitor | ~30m incl. CI |
| **Real-PR runtime test (steps 1-8 above)** | 20m |
| **Total** | **~1.5h hands-on + ~30m CI** |
