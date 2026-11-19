<!-- aidevops:brief-schema=v2 -->

# Duplicate PR consolidation stops scoring singleton PRs that cannot form a group

## Origin

Interactive productivity investigation (session mining of Pulse merge throughput). Found while tracing why CLEAN, APPROVED worker PRs in a large managed repo wait several merge passes.

## What

`_pmp_consolidate_duplicate_pr_groups` (`.agents/scripts/pulse-merge-duplicate-consolidation.sh:273`) runs on every deterministic merge pass. For each worker-owned PR with a linked issue it calls `_pmp_pr_consolidation_health_score`, which calls `_pr_required_checks_pass` (REST check-runs plus required-context and ruleset reads, about 6 s per PR). Only `_pmp_consolidate_duplicate_pr_group` uses the score, and it returns at once when an issue has fewer than two PRs. Almost every group is a singleton, so the pass pays for scores it never uses. Score only the PRs whose linked issue has two or more open worker PRs.

## Why

Read-only profile of one large managed repo (`<managed-repo>`, 40-42 open PRs), using the real merge-pass libraries with writes stubbed:

| Stage | Time |
|---|---|
| `_pmp_log_pr_backlog_counts` | 2-3 s |
| `_pmp_sort_prs_by_backlog_priority` | 4.4 s |
| `_pmp_consolidate_duplicate_pr_groups`, cold PR-view cache | 104-148 s |
| `_pmp_consolidate_duplicate_pr_groups`, warm PR-view cache (pulse default) | 69 s |
| one `_pr_required_checks_pass` | 5.9 s |
| one `_extract_linked_issue`, warm | 1.5 s |

Each run scored ten PRs, and none of them belonged to a duplicate group. Live `deterministic_merge_pass timing` rows for that repo show `other_s=64-182` (unattributed, which is where this call runs), `total_s=185-425`, and `merged=0` or `1` per pass. The repo slice is gone before a second PR is evaluated. The log has no `Duplicate PR consolidation` decision lines, and the last superseded close in that repo was on 2026-10-12. Meanwhile 6-13 merge-ready PRs wait several passes each. One CLEAN, APPROVED worker PR went green at 22:15Z, but the cursor had already passed it and it stayed unmerged.

## Tier

`tier:standard`: one function in one file, with an existing test suite and a clear equivalence argument.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-merge-duplicate-consolidation.sh:273-315`: split `_pmp_consolidate_duplicate_pr_groups` into a collect phase and a score phase. The model is the existing six-argument precomputed path in `_pmp_pr_consolidation_health_score` (`pulse-merge-duplicate-consolidation.sh:111-151`).

### Complete Write Surface

- **Callers/readers:** `_pmp_prepare_repo_processing_backlog` (`pulse-merge-backlog.sh:762`) is the only production caller and ignores the return value. `_pmp_consolidate_duplicate_pr_group` reads the group file in `issue|pr|score|created|draft` format, which stays unchanged.
- **Writers/mutation paths:** `_pmp_close_superseded_sibling_pr` (unchanged) is the only GitHub write. It runs only for verified multi-PR groups.
- **Schemas/config:** no change. The group-file row format stays the same, and `PULSE_MERGE_CONSOLIDATE_DUPLICATE_PRS` is still honoured.
- **Generated/deployed mirrors:** the deployed copy under `~/.aidevops/agents/scripts/` refreshes through `setup.sh` / `aidevops update`.
- **Migrations/backfills:** N/A. The group file is a per-call `mktemp` file, so no persisted state exists.
- **Cleanup/rollback paths:** to roll back, revert the PR. No persisted state exists to retire. The new candidate temp file is created and removed inside the function, next to the existing group file (`rm -f` before `return 0`). `PULSE_MERGE_CONSOLIDATE_DUPLICATE_PRS=false` remains the runtime kill switch (`pulse-merge-duplicate-consolidation.sh:280`).
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-merge-duplicate-pr-consolidation.sh`.

### Implementation Steps

1. Phase 1: keep the existing TSV loop and worker-owned and linked-issue filters, but write `issue|pr|created|draft|mergeable|review` candidate rows to a temp file without scoring.
2. Phase 2: for each issue listed by `cut -d'|' -f1 | sort | uniq -d`, score each of its candidate rows with `_pmp_pr_consolidation_health_score "$repo_slug" "" "$pr" "$mergeable" "$review" "$draft"` and append `issue|pr|score|created|draft` to the group file.
3. Keep the per-issue `_pmp_consolidate_duplicate_pr_group` loop unchanged, and keep `return 0` on every path.
4. Run ShellCheck and the focused test, then make a WIP commit.

### Hazards and Compatibility

- **Concurrency/atomicity:** per-call temp files only, so there is no shared state.
- **Migration/rollback:** behaviour-preserving. Rows dropped in phase 2 belong to singleton groups, which `_pmp_consolidate_duplicate_pr_group` already returns from at `group_count -gt 1`.
- **Mixed-version/backward compatibility:** no interface change. The function signature and return value are unchanged.
- **Idempotency/retry:** unchanged. Each pass recomputes from the live backlog.
- **Partial failure/recovery:** if a temp file cannot be created, fall back to the existing `${TMPDIR:-/tmp}` path pattern. Any failure leaves the function a no-op that returns 0.

### Complexity Impact

- **Target function:** `_pmp_consolidate_duplicate_pr_groups`, about 43 lines growing to about 60. That is under the 100-line function gate, so no extraction is needed.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-merge-duplicate-consolidation.sh
bash .agents/scripts/tests/test-pulse-merge-duplicate-pr-consolidation.sh
```

- **Surface mapping:** ShellCheck covers the edited script. The consolidation suite proves duplicate groups still score, select, verify and close as before. A read-only profile against the large managed repo proves the singleton backlog makes zero `_pr_required_checks_pass` calls.
- **Broad verification trigger:** Not required, because there are no shared config, root tooling or release infrastructure changes.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: the commands above
- [ ] WIP commit created before broad gates
- [ ] Evidence-triggered broad verification: not required, the change is scoped

### Scope Boundaries

**Hard boundaries:** do not change candidate selection, the health threshold, issue-label blocks, scope verification, or the close path. Do not change any other merge-pass stage.

**AI brief owner:** the interactive session that filed this task.

### Files Scope

- `.agents/scripts/pulse-merge-duplicate-consolidation.sh`
- `.agents/scripts/tests/test-pulse-merge-duplicate-pr-consolidation.sh`

## Acceptance Criteria

- [ ] A backlog with no duplicate linked issue makes zero `_pr_required_checks_pass` calls during consolidation (positive).
- [ ] A backlog with a duplicate worker PR group still scores, selects, verifies, and closes exactly as before: `test-pulse-merge-duplicate-pr-consolidation.sh` passes (negative regression).
- [ ] ShellCheck reports zero violations for the edited file.
- [ ] After deploy, the large repo's `deterministic_merge_pass timing` `other_s` falls well below the 64-182 s baseline.

## Context & Decisions

- Two other options were rejected for this task. Batching PR bodies through one REST pulls read would save the remaining body reads, but it changes the read path. Running consolidation only once per walk changes when duplicates are detected. Scoring only duplicated groups removes about 85% of the warm-cache cost and leaves outcomes unchanged.

## Relevant Files

- `.agents/scripts/pulse-merge-duplicate-consolidation.sh:111-151,211-315`
- `.agents/scripts/pulse-merge-backlog.sh:754-766`
- `.agents/scripts/pulse-merge-process.sh:623-638`

## Dependencies

None.
