<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2002: Phase 12 — split `_merge_ready_prs_for_repo()` (259 lines)

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent:** t1962 Phase 12 follow-up (plan §6, candidate #4)
- **Function location:** `.agents/scripts/pulse-merge.sh:547` (extracted in Phase 4, t1972 / #18379, second-largest function in codebase at extraction time)

## What

Split `_merge_ready_prs_for_repo()` into a per-PR processing inner loop. The current function fetches the PR list for a repo and inlines all per-PR processing (gate checks, merge eligibility, conflict detection, merge action) into one body. Extract the inner loop into `_process_single_ready_pr()`.

Target structure:
1. **`_merge_ready_prs_for_repo()`** — fetches the PR list for the given repo, iterates, calls `_process_single_ready_pr` for each. <60 lines.
2. **`_process_single_ready_pr()`** — handles one PR end-to-end: gate checks, merge attempt, conflict detection, comment posting. ~180 lines (still large but coherent).
3. Optionally further extract `_check_pr_merge_eligibility()` if there's a clean sub-seam.

## Why

- 259 lines, top of the violation list along with `dispatch_with_dedup`, `dispatch_triage_reviews`, `run_weekly_complexity_scan`.
- The function is hard to debug when a single PR fails: there's no isolation point to set a breakpoint or log "what happened with PR #X".
- Extracting per-PR processing makes it possible to write a unit test that feeds a single mock PR and asserts the gate decisions.

## Tier

`tier:standard`. The split is mechanical (loop body extraction) but the function is complex internally. Sonnet-tier model is appropriate.

## How

### Files to modify

- **EDIT:** `.agents/scripts/pulse-merge.sh:547-806` — `_merge_ready_prs_for_repo()` body
- **VERIFY:** caller is `merge_ready_prs_all_repos()` in same module, line 537. Should not need changes.

### Recommended split

1. Read the function. Identify the per-PR loop body — should start after a `gh pr list` call and span until the loop closes.
2. Extract the loop body into `_process_single_ready_pr()`. Pass in: PR number, PR JSON metadata, repo slug, self_login.
3. The new function should return 0 on successful merge, 1 on intentional skip (gate failure), other codes for actual failures.
4. Parent becomes: fetch list → for each → `_process_single_ready_pr "$pr"` → continue/break on result.

```bash
_merge_ready_prs_for_repo() {
    local repo="$1"
    local prs
    prs=$(gh pr list --repo "$repo" --state open --json ... ) || return 1
    local pr_obj
    while IFS= read -r pr_obj; do
        _process_single_ready_pr "$repo" "$pr_obj" || continue
    done <<<"$(echo "$prs" | jq -c '.[]')"
}
```

### Verification

```bash
bash -n .agents/scripts/pulse-merge.sh
.agents/scripts/pulse-wrapper.sh --self-check
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
bash .agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh  # exercises merge gates
SHELLCHECK_RSS_LIMIT_MB=4096 shellcheck .agents/scripts/pulse-merge.sh
# Sandbox dry-run
```

## Acceptance Criteria

- [ ] `_merge_ready_prs_for_repo()` reduced to under 60 lines (orchestrator only)
- [ ] `_process_single_ready_pr()` extracted, under 200 lines
- [ ] All existing pulse tests pass
- [ ] `--self-check` clean
- [ ] `shellcheck` no new findings
- [ ] No behavioural change observable in pulse log lines (compare a sandbox run before/after for the same fixture)

## Relevant Files

- `.agents/scripts/pulse-merge.sh:547`
- `.agents/scripts/pulse-merge.sh:537` — caller `merge_ready_prs_all_repos`
- Phase 0 characterization test (regression net)

## Dependencies

- **Related:** t1999, t2000, t2001 (sibling per-function splits)

## Estimate

~2h.
