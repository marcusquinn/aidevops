# t2395: fix(maintainer-gate): extend assignee-exemption to cover `source:*` automation-authored issues

## Session origin

- Date: 2026-04-19
- Context: Diagnostic session on `marcusquinn/aidevops` — every worker PR authored in the last 24h for review-followup / ci-feedback / quality-debt issues was closed-unmerged by the `Maintainer Review & Assignee Gate` check with the identical message `Issue #NNNN has no assignee`.
- Sibling tasks: t2394 (CLAIM_VOID), t2396 (reassign normalization), t2397 (HARD STOP age-out), t2398 (hot-deploy).

## What

`.github/workflows/maintainer-gate.yml` Job 1 Check 2 (lines 279-301) hardcodes the assignee exemption to `ISSUE_AUTHOR == "github-actions[bot]"`. Broaden the exemption so that scanner-authored and automation-routed issues qualify regardless of the author's `login`, using `source:*` labels as the non-spoofable signal (only the pulse process can apply the predefined scanner labels via labelled workflows).

## Why

**Root cause confirmed in production 2026-04-19.** Pulse scanners run as the repo **owner's** `gh` identity (e.g., `marcusquinn`), not as `github-actions[bot]`, because the pulse executes locally with the maintainer's PAT/OAuth. Example issue bodies from today:

- #19924 — `review-followup` + `source:review-scanner` + `source:ci-feedback` — `ISSUE_AUTHOR=marcusquinn`
- #19921 — `review-followup` + `source:review-scanner` + `source:ci-feedback` — `ISSUE_AUTHOR=marcusquinn`

Current Check 2 flow (copied from `maintainer-gate.yml:287-301`):

```yaml
if [[ "$ISSUE_AUTHOR" == "github-actions[bot]" ]] && [[ "$PR_AUTHOR_IS_MAINTAINER" == "true" ]]; then
  echo "EXEMPT: ..."
else
  BLOCKED=true
  REASONS="${REASONS}Issue #${ISSUE_NUM} has no assignee..."
fi
```

Workers DO self-assign at dispatch time via `_launch_worker` in `pulse-dispatch-worker-launch.sh`. But:
1. If the worker fast-fails → `pulse-cleanup.sh` unassigns + sets status:available
2. If the PR fails CI → `pulse-merge-feedback.sh` reroutes feedback to the issue and sets status:available (no explicit unassign, but the next dispatch cycle can clear it)
3. Job 3 re-runs Job 1 on issue state changes (t2018), but by the time the PR's next check runs, the issue has been reset — so Check 2 sees `assignees=[]` and blocks

**Precedent:** #18197 added an exemption for `simplification-debt` issues authored by the bot. Extending the exemption to cover ANY `source:*` automation label is the generalisation that closes the class of defects.

**Security reasoning:** `source:*` labels are non-spoofable because:
- GitHub label creation/application via the scanner scripts requires the repo owner's token (which workers don't have — they run with a limited-scope dispatch context).
- Contributors opening issues manually cannot apply arbitrary labels; only the pulse process (running as owner) can apply labels at issue-creation time.
- Even if a contributor could apply a scanner label, `PR_AUTHOR_IS_MAINTAINER` remains required — so the only way to bypass the gate is if BOTH (a) a scanner label is applied AND (b) a maintainer PR is opened. Either signal alone remains insufficient.

## How

### Files to modify

- **EDIT**: `.github/workflows/maintainer-gate.yml:279-301` (Job 1, the "Check 2: no assignee" block).
  - Add a new condition that considers the issue exempt when `LABELS` contains any of: `source:review-scanner`, `source:review-feedback`, `source:ci-feedback`, `source:ci-failure-miner`, `source:conflict-feedback`, `source:quality-debt`, `source:post-merge-review-scanner`, AND `PR_AUTHOR_IS_MAINTAINER == true`.
  - Keep the existing `ISSUE_AUTHOR == "github-actions[bot]"` branch for backwards compat.

- **EDIT**: `.github/workflows/maintainer-gate.yml` — update the comment block at lines 280-286 to document the new `source:*` exemption path and its security reasoning (the non-spoofable label property).

### Reference pattern

- Model on existing exemption logic at `maintainer-gate.yml:287-301`. Keep the same structure, add a second exemption branch.
- PR #18197 (CLOSED) is the canonical precedent for "extend exemption to labelled automation issues" — review its diff for style.
- Job 5's owner-allowlist broadening (referenced in the repo's `GH#18684`) is the parallel reasoning for why pulse-as-owner is a trusted actor.

### Proposed code shape

```yaml
# Check 2: no assignee
# Exempt when:
#   (a) Issue author is github-actions[bot] AND PR author is OWNER/MEMBER, OR
#   (b) Issue carries a source:* automation label AND PR author is OWNER/MEMBER.
# Both branches require PR_AUTHOR_IS_MAINTAINER as the additional safeguard.
if [[ -z "$ASSIGNEES" ]]; then
  PR_AUTHOR_IS_MAINTAINER=false
  if [[ "$PR_AUTHOR_ASSOCIATION" == "OWNER" || "$PR_AUTHOR_ASSOCIATION" == "MEMBER" ]]; then
    PR_AUTHOR_IS_MAINTAINER=true
  fi

  HAS_AUTOMATION_LABEL=false
  for automation_label in \
    "source:review-scanner" "source:review-feedback" "source:ci-feedback" \
    "source:ci-failure-miner" "source:conflict-feedback" "source:quality-debt" \
    "source:post-merge-review-scanner"; do
    if echo "$LABELS" | grep -qxF "$automation_label"; then
      HAS_AUTOMATION_LABEL=true
      break
    fi
  done

  if [[ "$PR_AUTHOR_IS_MAINTAINER" == "true" ]] && \
     { [[ "$ISSUE_AUTHOR" == "github-actions[bot]" ]] || [[ "$HAS_AUTOMATION_LABEL" == "true" ]]; }; then
    echo "EXEMPT: Issue #$ISSUE_NUM (issue_author=$ISSUE_AUTHOR automation_label=$HAS_AUTOMATION_LABEL pr_author=$PR_AUTHOR_ASSOCIATION) — assignee check skipped"
  else
    BLOCKED=true
    REASONS="${REASONS}Issue #${ISSUE_NUM} has no assignee..."
  fi
fi
```

## Acceptance criteria

1. Maintainer-gate passes for a PR authored by OWNER linking an issue with `source:review-scanner` label and no assignees.
2. Maintainer-gate passes for a PR linking an issue with `source:ci-feedback` label and no assignees, when PR author is OWNER/MEMBER.
3. Maintainer-gate still blocks for a PR authored by a first-time CONTRIBUTOR, even if the linked issue has a `source:*` label (security: label alone is insufficient).
4. Maintainer-gate still blocks for a PR linking an issue with NO `source:*` label and no assignees — existing behaviour preserved.
5. Existing exemption for `github-actions[bot]`-authored issues still works (backwards compat).
6. `actionlint .github/workflows/maintainer-gate.yml` passes.

## Verification

```bash
# Local syntax check
actionlint .github/workflows/maintainer-gate.yml

# Spot-check against current failing PRs (dry-run the gate logic)
gh api repos/marcusquinn/aidevops/issues/19924 --jq '{labels: [.labels[].name], assignees: [.assignees[].login], user: .user.login}'
# Expected: ["origin:worker", "review-followup", "source:review-scanner", "source:ci-feedback"], [], "marcusquinn"
# Post-fix: should be exempt

# Verification after merge: next scanner-created issue with a worker PR should pass the gate
gh pr checks <new-pr-number> --repo marcusquinn/aidevops | grep maintainer-gate
```

## Context

- Related merged work: #18197 (simplification-debt exemption — the precedent), #18478/#18521/t2037 (Job 3 refresh trigger), #18684 (origin:worker server-side protection).
- The gap: #18197 only covered `simplification-debt` label; this task extends the principle to all `source:*` automation labels for a consistent exemption surface.
- All GH-closed worker PRs in the last 24h that hit this block: #19944, #19940, #19934, #19903, #19897, #19895, #19888, #19887, #19879 (9+ closed-unmerged in one day — systemic, not incidental).
- Priority: HIGH — currently the #2 cause of PR loss in the worker pipeline (after CLAIM_VOID).
