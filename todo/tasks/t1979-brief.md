<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1979: branch protection — add Code Quality Analysis to required checks so complexity regressions block merge

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (follow-up from the t1968–t1970 session)
- **Created by:** ai-interactive
- **Parent task:** none
- **Conversation context:** During the t1968 PR (#18373) merge, the `Code Quality Analysis` workflow (which runs the complexity ratchet) was still `in_progress` at merge time. The auto-merge fired once the REQUIRED checks were green, and the complexity check finished a minute later with `failure`. The regression landed on main without blocking merge. Both follow-up PRs (#18374 and #18375) inherited the regression and had to carry a one-line fix to restore the threshold.

## What

Add `Code Quality Analysis` (or the specific job name `Complexity Analysis` — verify in the workflow YAML) to the set of required status checks for branch protection on `main` so that PRs cannot auto-merge while that check is pending, and cannot merge at all if it fails.

If the workflow aggregates multiple sub-jobs (Complexity Analysis, Qlty Maintainability Smells, Codacy, SonarCloud) under a parent name, decide whether to require the parent or each sub-job individually. Prefer the finest-grained job that always runs — if Codacy/SonarCloud can be absent on some PRs, require the complexity sub-job directly rather than the parent aggregate.

## Why

**Concrete evidence from this session:**

- PR #18373 (t1968) merged at `2026-04-12T17:11:51Z`
- `Code Quality Analysis` workflow timeline on that branch:
  - Started `2026-04-12T17:09:04Z`
  - Completed `2026-04-12T17:12:51Z` with conclusion `failure`
- Merge happened **60 seconds before the failing check completed**
- Both subsequent PRs in the session (#18374, #18375) had to carry a 1-line `setup.sh` revert to restore the threshold so CI would pass

The complexity ratchet is the framework's main defence against "quality decay by a thousand cuts" — functions gradually growing past the 100-line threshold, total violation count creeping up past the 40-line budget. If regressions can slip through while the check is pending, the ratchet is ornamental.

This isn't a hypothetical — it already happened once, cost roughly 15 minutes of follow-up work across two PRs to recover, and could easily happen again on a busy day with overlapping merges.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 1 (`.github/workflows/` or branch protection config via `gh api`)
- [ ] **Complete code blocks for every edit?** — need to read the current workflow and branch protection setup first
- [ ] **No judgment or design decisions?** — small: whether to require the parent workflow or the sub-job, whether to also require SonarCloud/Codacy which are external services that may be absent
- [x] **No error handling or fallback logic to design?** — no
- [x] **Estimate 1h or less?** — yes, ~45m including the investigation
- [x] **4 or fewer acceptance criteria?** — 3

**Selected tier:** `tier:standard`

**Tier rationale:** Small investigative component (read the workflow, inspect current branch protection) + a small config change. Not simple because it requires reading and deciding between require-parent vs require-sub-job. Not reasoning-tier because there's a clear pattern to follow.

## How (Approach)

### Files to Investigate

- `EDIT: .github/workflows/code-quality.yml` (or whatever file defines `Code Quality Analysis`) — find the `Complexity Analysis` job definition, note its exact check name as it appears in PR status
- `READ: gh api "repos/marcusquinn/aidevops/branches/main/protection"` — see current required status checks
- `READ: gh api "repos/marcusquinn/aidevops/branches/main/protection/required_status_checks"` — same, narrower

### Implementation Steps

1. Inspect the workflow:

    ```bash
    fd -t f 'code-quality|complexity' .github/workflows/ | xargs -I{} rg -l 'Complexity Analysis|complexity' {}
    ```

2. Inspect current branch protection required checks:

    ```bash
    gh api "repos/marcusquinn/aidevops/branches/main/protection" --jq '.required_status_checks'
    ```

3. Decide whether to add the parent workflow name or the sub-job. The recommendation is the sub-job (`Complexity Analysis`) because it's the specific guarantee we want. The parent may also include external services that can be flaky.

4. Add the check to branch protection. Two options:
   - Via `gh` CLI:

     ```bash
     gh api -X PATCH "repos/marcusquinn/aidevops/branches/main/protection/required_status_checks" \
         -f 'contexts[]=Complexity Analysis' \
         -f 'contexts[]=<existing check 1>' \
         -f 'contexts[]=<existing check 2>' \
         ...
     ```

     Note: the `contexts` array REPLACES the existing list, so include all current contexts plus the new one.
   - Via the web UI at `https://github.com/marcusquinn/aidevops/settings/branches`.

5. Verify: open a dummy PR that intentionally regresses complexity by 1 (add a dummy line to an at-threshold function) and confirm it cannot merge until the complexity check completes and passes.

### Verification

```bash
# Confirm the new check is in the required list
gh api "repos/marcusquinn/aidevops/branches/main/protection/required_status_checks" \
    --jq '.contexts[]' | grep -i complexity

# Integration: synthetic regression PR should be blocked from merge
# (manual test — create a throwaway branch with a 1-line addition to an
# at-threshold function, open PR, observe that merge-when-ready waits)
```

## Acceptance Criteria

- [ ] `Complexity Analysis` (exact name per workflow YAML) appears in `gh api "repos/.../required_status_checks" --jq '.contexts[]'` output.
- [ ] A synthetic regression PR with a 1-line addition to any at-threshold function cannot auto-merge while the complexity check is pending, and is blocked from merging when the check fails.
- [ ] No other existing required checks are accidentally removed (`gh api` context list mutation preserves the previous contents).

## Context & Decisions

- **Why not also require Qlty/SonarCloud/Codacy:** they're external services that occasionally rate-limit or time out. Making them required would create spurious blocks on unrelated PRs. Require only the in-repo complexity job; external tools remain advisory.
- **Why not widen the auto-merge script to wait for all pending checks:** that's a framework change to the auto-merge logic (likely in pulse-wrapper or a GitHub Actions workflow), with a broader blast radius. The simpler, narrower fix is to elevate the specific check we care about to "required" via branch protection. If other "should be blocking" checks emerge later, the same pattern applies.
- **Why not bump the complexity threshold:** the threshold is the ratchet's teeth. Bumping it would hide the regression, not prevent it.

## Relevant Files

- `.github/workflows/` — location of Code Quality Analysis workflow (exact file TBD by investigation)
- `.agents/configs/complexity-thresholds.conf` — the threshold file the ratchet reads
- `.agents/scripts/complexity-scan-helper.sh` — the local scanner (referenced for context only — this task is about CI-side enforcement)
- Evidence: `gh run view 24312089227` (t1969's failing Code Quality run) and `gh run view 24311978424` (t1970's failing run) for the pre-fix failure log showing exact job names and output format

## Dependencies

- **Blocked by:** none
- **Blocks:** none (quality-of-life improvement)
- **External:** requires admin access to branch protection settings. Only the repo owner or an admin collaborator can change required checks.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Investigation | 15m | Read workflow YAML, inspect current branch protection |
| Config change | 10m | Single `gh api` call or UI click |
| Verification | 15m | Synthetic regression PR, confirm merge blocked |
| PR (if any) | 5m | Only if workflow YAML needs editing to rename the check context |

**Total estimate:** ~45m
