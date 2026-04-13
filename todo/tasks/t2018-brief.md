---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2018: fix(maintainer-gate): Job 3 re-runs Job 1 to refresh required CheckRun after issue state changes

## Origin

- **Created:** 2026-04-13
- **Session:** Claude:interactive
- **Created by:** marcusquinn (ai-interactive, gap observed during /pr-loop execution on #18474)
- **Parent task:** none
- **Conversation context:** While driving PR #18474 (the fix for GH#18429, t2015) through `/pr-loop`, the maintainer gate blocked merge until @marcusquinn ran `sudo aidevops approve issue 18429`. The approval succeeded — the signed comment was posted, `needs-maintainer-review` was removed, the issue was assigned — but the required CheckRun `Maintainer Review & Assignee Gate` stayed stuck on its PR-creation-time failure. I manually re-ran the workflow (`gh run rerun 24319220270`) to clear it. This same stuck-gate pattern will hit every future session (interactive or headless) that approves an issue after the linked PR is already open. Fix the root cause in `.github/workflows/maintainer-gate.yml` so Job 3's re-evaluation actually refreshes the required check.

## What

After a maintainer clears a gate-relevant issue state (`needs-maintainer-review` label removed via signed approval, or `assignee` added), the required CheckRun `Maintainer Review & Assignee Gate` on the linked PR(s) refreshes automatically — without anyone having to manually re-run the workflow.

End-state: an interactive or headless session that runs `sudo aidevops approve issue <N>` (or otherwise changes gate state) sees the PR's required check flip from FAILURE to SUCCESS within ~20 seconds, and the PR becomes mergeable without further human/LLM intervention.

## Why

**The problem in one paragraph.** `.github/workflows/maintainer-gate.yml` has two jobs that write gate state, and they write to two different names. Job 1 (`check-pr`, on `pull_request_target`) produces a CheckRun from its job name `Maintainer Review & Assignee Gate` — this is the name on the `required_status_checks` list in branch protection. Job 3 (`retrigger-pr-checks`, on `issues`) posts a StatusContext named `maintainer-gate` (lowercase). Branch protection matches by name, so Job 3's posts never update Job 1's required CheckRun. When an approval happens after PR open, Job 1 never re-runs on its own (there's no `pull_request_target` event), and the required CheckRun stays stuck on the stale failure forever.

**Why the current design is broken by default.** The common path for externally-reported issues is:
1. External contributor opens issue with `needs-maintainer-review`.
2. Someone (maintainer, AI session) triages and opens a PR before approval — saves a round trip.
3. Maintainer runs `sudo aidevops approve issue <N>`.
4. Approval is posted, `needs-maintainer-review` is removed by the approval-helper, `protect-labels` job accepts the removal (signed comment found).
5. User expects the PR to become mergeable within a minute.

Instead, the PR stays blocked indefinitely until someone spots that the required CheckRun is stale and manually re-runs the `Maintainer Gate` workflow. This is invisible unless you know to look for it — the `maintainer-gate` StatusContext posted by Job 3 shows SUCCESS, which looks like "everything passes", but the required CheckRun still says FAILURE. An LLM worker would loop waiting for a state that will never auto-update, burning tokens and compute.

**Scope of impact.** Every externally-reported bug that goes through the `needs-maintainer-review` → PR → approve flow hits this. That's the primary reporting path for non-collaborators on the repo.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — 1 file: `.github/workflows/maintainer-gate.yml`
- [x] **Complete code blocks for every edit?** — yes, exact additions below in context
- [x] **No judgment or design decisions?** — approach chosen and justified in Context & Decisions; the edit is straightforward
- [x] **No error handling or fallback logic to design?** — fail-open warnings matching the surrounding `|| true` style
- [x] **Estimate 1h or less?** — ~30-40 minutes including the gate-check self-test
- [x] **4 or fewer acceptance criteria?** — exactly 4

All checked = `tier:simple`. 

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file workflow edit. The approach is fully specified (add `actions: write` permission, append a shell block that finds and re-runs the latest `check-pr` job via REST API). Reviewer copies the diff and verifies, no architectural judgment required.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/maintainer-gate.yml` — two changes to Job 3 (`retrigger-pr-checks`):
  1. Add `actions: write` to the `permissions:` block (currently `pull-requests: read, issues: read, contents: read, statuses: write` at lines 455-459).
  2. After the existing "post final status" block (lines 667-684, inside the `for PR_NUM in $OPEN_PRS` loop), add a new block that finds the latest completed `check-pr` workflow run for the PR's HEAD SHA and, if its conclusion was not `success`, calls `POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun-failed-jobs` to refresh it.

### Implementation Steps

**Step 1: Update Job 3's permissions block**

Find this block at `.github/workflows/maintainer-gate.yml:455-459`:

```yaml
    permissions:
      pull-requests: read
      issues: read
      contents: read
      statuses: write
```

Replace with:

```yaml
    permissions:
      pull-requests: read
      issues: read
      contents: read
      statuses: write
      actions: write  # t2018: allow re-running Job 1 to refresh required CheckRun
```

**Step 2: Add the re-run block at the end of Job 3's per-PR loop**

Find this closing sequence at `.github/workflows/maintainer-gate.yml:667-685` — it's the "post final status" block at the end of the `for PR_NUM in $OPEN_PRS` loop:

```bash
            # Post final status
            if [[ "$BLOCKED" == "true" ]]; then
              echo "Gate BLOCKED for PR #$PR_NUM: $DESCRIPTION"
              gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
                --method POST \
                -f state=failure \
                -f context="maintainer-gate" \
                -f description="$DESCRIPTION" \
                2>/dev/null || echo "::warning::Could not post failure status on PR #$PR_NUM"
            else
              echo "Gate PASSED for PR #$PR_NUM"
              gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
                --method POST \
                -f state=success \
                -f context="maintainer-gate" \
                -f description="$DESCRIPTION" \
                2>/dev/null || echo "::warning::Could not post success status on PR #$PR_NUM"
            fi
          done
```

Replace with (note: only the closing `done` stays the same; we add a new block BEFORE it):

```bash
            # Post final status
            if [[ "$BLOCKED" == "true" ]]; then
              echo "Gate BLOCKED for PR #$PR_NUM: $DESCRIPTION"
              gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
                --method POST \
                -f state=failure \
                -f context="maintainer-gate" \
                -f description="$DESCRIPTION" \
                2>/dev/null || echo "::warning::Could not post failure status on PR #$PR_NUM"
            else
              echo "Gate PASSED for PR #$PR_NUM"
              gh api "repos/${REPO}/statuses/${HEAD_SHA}" \
                --method POST \
                -f state=success \
                -f context="maintainer-gate" \
                -f description="$DESCRIPTION" \
                2>/dev/null || echo "::warning::Could not post success status on PR #$PR_NUM"
            fi

            # -----------------------------------------------------------------
            # t2018: refresh the REQUIRED CheckRun by re-running Job 1.
            #
            # The `maintainer-gate` status context posted above is NOT the
            # required check — branch protection requires the CheckRun
            # "Maintainer Review & Assignee Gate" produced by Job 1's job name.
            # Job 1 only runs on `pull_request_target` events, so when an
            # approval happens AFTER the PR is opened the required CheckRun
            # stays stuck on its stale PR-creation-time failure until someone
            # manually re-runs the workflow.
            #
            # Fix: find the latest completed `check-pr` workflow run for this
            # PR's HEAD SHA and re-run its failed jobs if its conclusion was
            # not `success`. The re-run creates a new CheckRun with the same
            # required name, and branch protection uses the latest one.
            #
            # Job 1 is idempotent — it reads issue state via gh api at runtime
            # rather than caching — so re-running reflects the post-approval
            # state automatically.
            # -----------------------------------------------------------------
            LATEST_RUN_ID=$(gh api \
              "repos/${REPO}/actions/workflows/maintainer-gate.yml/runs?head_sha=${HEAD_SHA}&event=pull_request_target&per_page=1" \
              --jq '.workflow_runs[0] | [.id, .conclusion] | @tsv' \
              2>/dev/null || true)

            if [[ -z "$LATEST_RUN_ID" ]]; then
              echo "No prior maintainer-gate run found for PR #$PR_NUM at $HEAD_SHA — skipping CheckRun refresh"
            else
              RUN_ID=$(printf '%s' "$LATEST_RUN_ID" | cut -f1)
              RUN_CONCLUSION=$(printf '%s' "$LATEST_RUN_ID" | cut -f2)
              if [[ "$RUN_CONCLUSION" == "success" ]]; then
                echo "Latest Job 1 run $RUN_ID already succeeded — no refresh needed"
              elif [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
                echo "::warning::Could not parse run id from Job 1 lookup for PR #$PR_NUM"
              else
                echo "Refreshing required CheckRun: re-running Job 1 (run_id=$RUN_ID, prior=$RUN_CONCLUSION) for PR #$PR_NUM"
                gh api \
                  "repos/${REPO}/actions/runs/${RUN_ID}/rerun-failed-jobs" \
                  --method POST \
                  2>/dev/null \
                  || echo "::warning::Failed to re-run Job 1 for PR #$PR_NUM — required CheckRun may remain stale until the next pull_request_target event"
              fi
            fi
          done
```

**Step 3: YAML lint and syntax check**

```bash
# The framework uses workflow-lint-helper.sh if available; otherwise use python
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/maintainer-gate.yml'))" \
  && echo "YAML parses cleanly"
# If actionlint is installed locally, run it too:
which actionlint >/dev/null 2>&1 && actionlint .github/workflows/maintainer-gate.yml
```

**Step 4: Push and let the workflow self-test**

The ultimate verification is the next externally-reported issue flow: approve an issue with an open linked PR, watch the required CheckRun flip to SUCCESS within ~20 seconds without manual re-run. Document this in the PR body as the runtime verification evidence.

### Verification

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/maintainer-gate.yml'))" \
  && grep -n "rerun-failed-jobs" .github/workflows/maintainer-gate.yml \
  && grep -n "actions: write  # t2018" .github/workflows/maintainer-gate.yml
```

## Acceptance Criteria

- [ ] `.github/workflows/maintainer-gate.yml` Job 3 has `actions: write` in its `permissions:` block.
  ```yaml
  verify:
    method: codebase
    pattern: "actions: write\\s*#\\s*t2018"
    path: ".github/workflows/maintainer-gate.yml"
  ```
- [ ] Job 3 calls `rerun-failed-jobs` after posting its final status context.
  ```yaml
  verify:
    method: codebase
    pattern: "rerun-failed-jobs"
    path: ".github/workflows/maintainer-gate.yml"
  ```
- [ ] The workflow file still parses as valid YAML.
  ```yaml
  verify:
    method: bash
    run: "python3 -c 'import yaml; yaml.safe_load(open(\".github/workflows/maintainer-gate.yml\"))'"
  ```
- [ ] When a gate-relevant issue event fires on an issue with an open linked PR whose Job 1 conclusion was `failure`, Job 3 re-runs Job 1 and the required `Maintainer Review & Assignee Gate` CheckRun refreshes. (Runtime-verified on the next externally-reported issue flow — no synthetic test possible without a live external contributor.)
  ```yaml
  verify:
    method: manual
    prompt: "After merge: on the next external bug report that goes through the needs-maintainer-review → PR → sudo aidevops approve issue N flow, confirm the required CheckRun flips to SUCCESS within ~20 seconds of the approval comment being posted, without any manual re-run."
  ```

## Context & Decisions

**Approaches considered.** Three candidates evaluated before choosing the rerun approach:

1. **Job 3 posts a new CheckRun directly via `POST /check-runs`.** Gives instant result. Rejected because it duplicates Job 1's gate logic (already partially duplicated in Job 3's inline evaluation) and would make Job 3 authoritative for the CheckRun while Job 1 still runs on PR events — two sources of truth for the same required check. Drift risk is real: if one of them gets a bug fix and the other doesn't, the two checks disagree.

2. **Change branch protection to require the `maintainer-gate` StatusContext instead of the CheckRun.** One-click setting change, no code. Rejected because the CheckRun name is referenced in PR comments, documentation, and the AGENTS.md gate description. Silent rename would be confusing for contributors already used to the existing name, and the StatusContext is also posted by Job 1 so it's not strictly simpler.

3. **Chosen: Job 3 re-runs Job 1's `check-pr` via `rerun-failed-jobs`.** Job 1 stays the single source of truth. Re-run creates a fresh CheckRun with the same name. Job 1 is already idempotent (reads state via `gh api`), so re-running produces a correct fresh result. Minimal code change. The trade-off is ~15 seconds of latency vs the instant approach — acceptable because the user flow is "run `sudo` command, wait a bit, see green" not a real-time interactive loop.

**Why re-run ALL non-success runs, not just failures?** `cancelled`, `action_required`, and `null` (in progress) conclusions all indicate the CheckRun is NOT reflecting current state. Re-running is safe and idempotent. The `success` short-circuit prevents wasted compute on the common case where nothing changed.

**What about the inline gate evaluation already in Job 3?** Job 3 still does its own evaluation and posts a `maintainer-gate` status context. That stays as-is — it serves two purposes: (1) visibility into Job 3's decision in the checks list, (2) a fast-path signal before the slower Job 1 re-run completes. Removing it would be a larger cleanup and not in scope here.

**Non-goals:**
- Removing the duplicate gate logic in Job 3 (bigger cleanup, separate task).
- Changing what triggers Job 1 (e.g., adding a manual `workflow_dispatch`).
- Changing the branch protection required check name.
- Testing the rerun API mock/contract — the real behaviour is observable on the next external issue flow.

## Relevant Files

- `.github/workflows/maintainer-gate.yml:35-373` — Job 1 `check-pr`, produces the required CheckRun.
- `.github/workflows/maintainer-gate.yml:444-685` — Job 3 `retrigger-pr-checks`, the file to edit.
- `.github/workflows/maintainer-gate.yml:455-459` — Job 3's permissions block (edit target 1).
- `.github/workflows/maintainer-gate.yml:667-685` — Job 3's "post final status" block (edit target 2, append after).
- https://docs.github.com/en/rest/actions/workflow-runs#re-run-failed-jobs-from-a-workflow-run — API reference for the rerun endpoint.

## Dependencies

- **Blocked by:** none
- **Blocks:** every future `/pr-loop` session driving an externally-reported bug through approval. Not a hard block — can be worked around manually — but it's a papercut that will keep burning token budget until fixed.
- **External:** GitHub Actions REST API (`actions:write` permission required — GitHub Actions default `GITHUB_TOKEN` supports this scope when declared in `permissions:`).

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | (done) | Already read all 828 lines of maintainer-gate.yml during the t2015 pr-loop troubleshooting — this brief captures that context. |
| Implementation | 10m | Two small edits to one file. |
| YAML + sanity check | 5m | `python3 yaml.safe_load`, grep checks, visual review of the diff. |
| PR merge and runtime observation | ~25m | PR open, CI, merge, then wait for next external issue or simulate by running `sudo aidevops approve` on a synthetic test issue if one is available. |
| **Total** | **~40m** | |
