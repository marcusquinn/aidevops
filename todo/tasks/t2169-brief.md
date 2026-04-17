<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2169: simplification-outcome-check workflow — Fix D of t2163

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:interactive (Claude Sonnet 4.7)
- **Created by:** Marcus Quinn (ai-interactive)
- **Parent task:** t2163 / GH#19482 (5-fix plan)
- **Conversation context:** Filed after t2164 (Fixes A+B) merged. Addresses the original root cause — PRs that merge claiming to solve file-size debt without actually reducing the file. Fix B verifies at gate time; Fix D verifies at merge time. Together they prevent phantom continuations at both ends of the lifecycle.

## What

Add a GitHub Actions workflow `.github/workflows/simplification-outcome-check.yml` that runs on every merged PR. When the PR body declares it closes a `file-size-debt` issue (post-Fix-C from t2168), the workflow verifies the target file is now under `LARGE_FILE_LINE_THRESHOLD` (2000 lines). If not, the workflow reopens the issue, applies a `simplification-incomplete` label, and posts a diagnostic comment on both the reopened issue and the PR.

Also update `_large_file_gate_verify_prior_reduced_size` in `pulse-dispatch-large-file-gate.sh` to short-circuit via the `simplification-incomplete` label — when the label is present, the gate can skip the `wc -l` check and immediately classify the prior issue as phantom. This reduces gate latency on re-evaluation.

## Why

Evidence: **PR #18715 closed simplification-debt #18706 for `issue-sync-helper.sh` while adding net +29 lines** (2165 → 2194). Without an outcome check, this state is invisible until the next pulse cycle's gate evaluation on a new parent — at which point the gate cites #18706 as "continuation" and blocks the new parent behind a phantom.

Fix B (t2164) mitigates this at evaluation time: the gate now verifies `wc -l` before emitting continuation. But:

1. The failure happens at merge time; the gate doesn't catch it until the next evaluation (potentially hours later).
2. The issue stays closed with a "resolved" appearance even though it wasn't resolved, leading humans to miss the regression.
3. Fix B's `wc -l` runs on every gate call — per-file disk cost scales with the number of gated issues.

The outcome check addresses all three: catches at merge time, reopens the issue so it shows `open` state correctly, and provides a label short-circuit so Fix B's `wc -l` only needs to run when the label is absent.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** New GitHub Actions workflow following the pattern of existing post-merge verification workflows (e.g. `qlty-regression.yml`, `parent-task-keyword-check.yml`). Narrative brief with trigger/step breakdown. Not `tier:simple` because the workflow has multiple steps with conditional logic (body parsing, file path extraction, conditional reopen+label). Not `tier:thinking` because no novel design — the workflow structure is established.

## How

### Files to modify

- **NEW:** `.github/workflows/simplification-outcome-check.yml`

  ```yaml
  name: Simplification Outcome Check
  on:
    pull_request_target:
      types: [closed]
  permissions:
    issues: write
    pull-requests: write
    contents: read
  jobs:
    outcome-check:
      if: github.event.pull_request.merged == true
      runs-on: ubuntu-latest
      steps:
        - name: Extract cited issue
          id: extract
          # Parse PR body for Closes #N / Resolves #N / Fixes #N
          # If no match, exit 0 (not applicable)
        - name: Check issue has file-size-debt label
          id: check-label
          # gh issue view N --json labels
          # If no file-size-debt, exit 0 (not applicable)
        - name: Extract target file path from issue body
          id: extract-path
          # Parse issue body for "Simplify `path`" line
        - name: Checkout merged commit
          uses: actions/checkout@v4
          with:
            ref: ${{ github.event.pull_request.merge_commit_sha }}
        - name: Measure file
          id: measure
          run: |
            if [ ! -f "$TARGET_FILE" ]; then
              echo "skip_reason=file-not-found" >> "$GITHUB_OUTPUT"
              exit 0
            fi
            lines=$(wc -l < "$TARGET_FILE")
            echo "lines=$lines" >> "$GITHUB_OUTPUT"
        - name: Reopen issue if file still over threshold
          if: steps.measure.outputs.lines >= env.THRESHOLD
          env:
            THRESHOLD: 2000
          run: |
            gh label create simplification-incomplete --repo "$REPO" \
              --description "PR merged without reducing file below threshold" \
              --color "B60205" --force || true
            gh issue reopen "$ISSUE_NUM" --repo "$REPO"
            gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "simplification-incomplete"
            gh issue comment "$ISSUE_NUM" --repo "$REPO" --body-file /tmp/comment.md
            gh pr comment "$PR_NUM" --repo "$REPO" --body "Outcome check: target file still $LINES lines (threshold 2000). Reopening #$ISSUE_NUM."
  ```

- **EDIT:** `.agents/scripts/pulse-dispatch-large-file-gate.sh` — `_large_file_gate_verify_prior_reduced_size` (~line 307-337)
  - Before the `wc -l` check: query the closed issue's labels via `gh issue view N --json labels --jq`
  - If the label set contains `simplification-incomplete`, return 1 immediately (phantom continuation)
  - Log the short-circuit: `[pulse-wrapper] Large-file gate: prior issue #N has simplification-incomplete label; filing fresh debt (outcome-check short-circuit)`
  - Keep the `wc -l` fallback for the (rare) case where the label is missing but the file is genuinely over threshold

### Reference patterns

- Workflow structure: `.github/workflows/qlty-regression.yml` (pull_request_target, conditional logic, `gh` commands)
- Parent-keyword parsing: `.github/workflows/parent-task-keyword-check.yml` or `full-loop-helper.sh commit-and-pr` (both parse `Closes`/`Resolves`/`Fixes`)
- Issue-body path extraction: issue body format set by `_large_file_gate_file_new_debt_issue:410-423` (`Simplify \`${lf_path}\``)
- Label short-circuit style: existing `_large_file_gate_precheck_labels:55-60` pattern (conditional + log + early return)

### Verification

```bash
# Unit test: simulate merge with file over threshold → workflow reopens
bash .agents/scripts/tests/test-simplification-outcome-check.sh

# Historical dry-run (manual trigger via workflow_dispatch input)
gh workflow run simplification-outcome-check.yml -f pr_number=18715
# Expected: reopens #18706 and applies simplification-incomplete label

# Short-circuit test: call _large_file_gate_verify_prior_reduced_size with a
# closed issue carrying simplification-incomplete — should return 1 without wc-l
bash .agents/scripts/tests/test-large-file-gate-continuation-verify.sh  # extend with new case
```

## Acceptance criteria

- [ ] `.github/workflows/simplification-outcome-check.yml` exists and triggers on merged PRs
- [ ] Workflow extracts cited issue number from PR body
- [ ] Workflow no-ops when cited issue has no `file-size-debt` label (applicability filter)
- [ ] Workflow reopens issue + applies `simplification-incomplete` label when file still over threshold
- [ ] Workflow comments on both PR and issue with measurement evidence
- [ ] `simplification-incomplete` label is created idempotently (no failure if already present)
- [ ] `_large_file_gate_verify_prior_reduced_size` short-circuits on the new label
- [ ] Regression test covers: over-threshold + reopen, under-threshold + no-op, missing-file + skip, no-label + skip
- [ ] Historical dry-run on PR #18715 correctly flags #18706 as incomplete

## Out of scope

- Blocking PR merge when outcome would be incomplete (merge is already done by the time `pull_request_target: closed` fires; pre-merge gating is a separate concern)
- Auto-creating follow-up issues when outcome is incomplete — reopening the original is sufficient signal
- Cross-repo outcome checks (scope is within the repo the workflow ships in)
- Migrating existing closed `file-size-debt` issues to back-fill the label — one-shot script is out of scope for this workflow

## PR Conventions

Leaf child of `parent-task` #19482. PR body MUST use `For #19482` (NOT `Closes`/`Resolves`). `Resolves #19498` closes this leaf issue when the PR merges. Only the FINAL phase child (the last of Fixes C/D/E to merge) uses `Closes #19482`.

Depends on t2168 (Fix C) landing first — the `file-size-debt` label name is introduced there. If t2168 is still in flight when this work starts, coordinate on branch naming or defer until t2168 merges.
