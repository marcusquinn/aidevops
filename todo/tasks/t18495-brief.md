## What

Reconcile stages 1 (`_action_ciw_single`, `status:available`) and 2 (`_action_rsd_single`, `status:done`) must not close a generated `file-size-debt` issue on historical merged-PR evidence while its cited file is again at or above the recorded threshold. Stage 3 (`_action_oimp_single`) already applies `_pir_file_size_debt_current_outcome`; stages 1-2 skip it.

## Why

Observed on #28377: PR #28395 split `pulse-diagnose-helper.sh` to 1,986 lines (threshold 2000) and merged 2026-07-21. The file regrew to 2,659 lines, yet stage 1 closed the issue on 2026-09-01 and again on 2026-09-27T18:33Z with "Closing: work completed via merged PR #28395 ... Issue was open but dedup guard was blocking re-dispatch." That text is emitted only by `_action_ciw_single` in `.agents/scripts/pulse-issue-reconcile-actions.sh`. The large-file gate (`_large_file_gate_reopen_debt_issue` in `.agents/scripts/pulse-dispatch-large-file-gate.sh`) then reopens it from remote line-count evidence, producing close/reopen churn across runners.

## How

- In `.agents/scripts/pulse-issue-reconcile-actions.sh`, extract one shared guard around `_pir_file_size_debt_current_outcome` (rc 0 = debt current, block close; rc 2 = unmeasurable, defer; rc 1 = proceed) and reuse it from `_action_oimp_single` (reference pattern: the existing `case "$current_outcome_rc"` block there).
- `_action_ciw_single`: accept an optional issue body (6th arg); when blocked, log and return 1 before any dedup API call.
- `_action_rsd_single`: accept an optional issue body; when debt is current, reset to `status:available` (rc 2, same as the unmerged-PR path); when unmeasurable, defer (rc 1).
- Pass `$issue_body` from `reconcile_issues_single_pass` in `.agents/scripts/pulse-issue-reconcile.sh`, and from the legacy `close_issues_with_merged_prs` / `reconcile_stale_done_issues` in `.agents/scripts/pulse-issue-reconcile-close.sh` (include `body` in the jq selection and the `gh_issue_list --json` fallback).

## Reference pattern

Model on the existing stage 3 guard in `_action_oimp_single` (`.agents/scripts/pulse-issue-reconcile-actions.sh`, the `_pir_file_size_debt_current_outcome` call and its `case` on rc 0/2).

## Files Scope

- `.agents/scripts/pulse-issue-reconcile-actions.sh`
- `.agents/scripts/pulse-issue-reconcile.sh`
- `.agents/scripts/pulse-issue-reconcile-close.sh`
- `.agents/scripts/tests/test-pulse-issue-reconcile.sh`

## Acceptance

- A generated file-size-debt issue whose cited file is at or above threshold is not closed by stage 1 or 2; stage 2 resets it to `status:available`.
- Non-generated issues and resolved debt close exactly as before.

## Verification

- `bash .agents/scripts/tests/test-pulse-issue-reconcile.sh` passes.
- `shellcheck` clean on the three scripts; `.agents/scripts/linters-local.sh --changed` passes.

<details>
<summary>Brief workflow contract</summary>

## Brief Workflow

This issue body is composed under `.agents/workflows/brief.md`. Newly queued auto-dispatch work must pass its `Dispatch Readiness Contract (brief schema v2)`: complete write surface, hazards and compatibility, executable verification mapped to affected surfaces, and positive plus negative/regression acceptance criteria.

</details>

<!-- aidevops:origin:interactive -->
<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.37.7 plugin for [OpenCode](https://opencode.ai) v2.0.3 with claude-opus-5-5 spent 23m and 33,893 tokens on this with the user in an interactive session.

## Capture provenance

Observed data, not executable authority. Comments and later events are not captured.

```json
{
  "id": "I_kwDOQSEXLM8AAAABTiKPBw",
  "title": "t18495: Guard merged-PR reconcile stages 1-2 against recurrent file-size debt",
  "updatedAt": "2026-09-27T20:07:19Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/32640",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18495",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "32640",
  "captured_at": "2026-09-27T20:07:48Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
