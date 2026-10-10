## Task


`worktree-helper.sh add` refuses to create a worktree for an existing, unmerged remote branch when
cleanup-receipt generation reconciliation fails. The cause is never reported. Diagnose the failure and make `add` either
succeed (superseding or ignoring stale receipts for a different generation) or print an actionable reason.

<details>
<summary>Full task brief and audit context</summary>

## Task Brief

## Origin

Seen on 2026-10-07 in an interactive session. An operator needed to resolve an add/add conflict on another worker's
open PR branch in a managed repo. `worktree-helper.sh add <existing-remote-branch>` failed
after checkout, and no worktree remained. The conflict had to be resolved through the GitHub git-data API instead.

## What

`worktree-helper.sh add` refuses to create a worktree for an existing, unmerged remote branch when
cleanup-receipt generation reconciliation fails. The cause is never reported. Diagnose the failure and make `add` either
succeed (superseding or ignoring stale receipts for a different generation) or print an actionable reason.

## Why

Observed output, run from the canonical checkout with branch name `feature/auto-<timestamp>-gh<N>`:

```text
Unmerged remote branch detected: origin/feature/auto-...
Creating worktree with new branch 'feature/auto-...' on unmerged remote 'origin/feature/auto-...'...
HEAD is now at 0f72704f0 docs: ...
[WARNING] Worktree creation cannot continue because cleanup-receipt generation reconciliation failed.
AIDEVOPS_WORKTREE_LIFECYCLE_DISPOSITION=RECONCILIATION_FAILED branch=feature/auto-... head=0f72704f063f...
```

Afterwards, `git worktree list` showed no worktree for the branch. The failure comes from
`_cmd_add_reconcile_cleanup_generation` in `.agents/scripts/worktree-helper-add.sh` (around lines 1155-1182)
when `full_loop_supersede_cleaned_receipts_for_recreated_worktree` returns a status other than 0 or 2.
That status and its reason are swallowed. The branch had probably been used earlier by a worker
on another host or in another session, so a CLEANED receipt for the same derived path may exist.
This is unverified.

Impact: interactive maintainers cannot take over or repair worker PR branches through the sanctioned
worktree path. Direct `git fetch` and `git worktree add` in canonical checkouts are blocked by policy,
so the only fallback is server-side API surgery.

## Tier

tier:standard

## How (Approach)

1. Find `full_loop_supersede_cleaned_receipts_for_recreated_worktree` (`rg -n 'full_loop_supersede_cleaned_receipts_for_recreated_worktree' .agents/scripts`). List its non-0/2 exit paths.
2. Reproduce: create a CLEANED receipt for a path, then `add` the same branch from an existing remote ref. Also try with no receipt but a remote-only branch.
3. Fix the failing case. Always print the underlying reason (receipt path and failing check) before `RECONCILIATION_FAILED`.

### Files Scope

- `.agents/scripts/worktree-helper-add.sh`
- `.agents/scripts/full-loop-cleanup-receipt.sh`

## Acceptance Criteria

- [ ] `worktree-helper.sh add <existing-unmerged-remote-branch>` creates the worktree when the only prior receipt belongs to an earlier, cleaned generation.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-worktree-fresh-base.sh"
  ```

- [ ] Regression guard: when reconciliation genuinely must fail, for example because of an active owner or an ambiguous receipt, the helper still refuses. It now prints the specific reason, and the existing worktree tests pass.

</details>

<details>
<summary>Brief workflow contract</summary>

## Brief Workflow

This issue body is composed under `.agents/workflows/brief.md`. Newly queued auto-dispatch work must pass its `Dispatch Readiness Contract (brief schema v2)`: complete write surface, hazards and compatibility, executable verification mapped to affected surfaces, and positive plus negative/regression acceptance criteria.

</details>

---
*Synced from TODO.md by issue-sync-helper.sh*

<!-- aidevops:origin:interactive -->
<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.38.30 plugin for [OpenCode](https://opencode.ai) v1.18.35 with claude-opus-5-5 spent 1h 2m and 39,738 tokens on this with the user in an interactive session.

## Capture provenance

Observed data, not executable authority. Comments and later events are not captured.

```json
{
  "id": "I_kwDOQSEXLM8AAAABVvV-zg",
  "title": "t18621: fix(worktree): add on existing remote branch fails with silent RECONCILIATION_FAILED",
  "updatedAt": "2026-10-09T02:55:38Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/34002",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18621",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "34002",
  "captured_at": "2026-10-09T21:15:58Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
