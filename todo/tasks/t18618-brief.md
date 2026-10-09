## Task


Let the worker-briefed auto-merge path accept a PR whose only issue reference is a non-closing
`For #NNN`/`Ref #NNN`. All three conditions must hold:
- the referenced issue is open,
- it is not labelled `parent-task`,
- it has the same trust and NMR properties already checked for closing-keyword links.

The merge must not close the issue: the squash commit must contain no closing keyword. Parent-task
references (`For #parent`) must stay ineligible.

<details>
<summary>Full task brief and audit context</summary>

## Task Brief

## Origin

Found on 2026-10-07 during an interactive check of PRs that looked stuck in a managed private repo.
There were 13 green, CLEAN, non-draft `origin:worker` multi-phase enrichment PRs. Each linked its issue
with `For #NNN` because the enrichment issue stays open for later phases. Pulse skipped every one with
`worker-briefed auto-merge: skipping PR #N — no linked issue (t2449)`, about 16 to 17 times each. In the end
they all had to be merged by hand.

## What

Let the worker-briefed auto-merge path accept a PR whose only issue reference is a non-closing
`For #NNN`/`Ref #NNN`. All three conditions must hold:
- the referenced issue is open,
- it is not labelled `parent-task`,
- it has the same trust and NMR properties already checked for closing-keyword links.

The merge must not close the issue: the squash commit must contain no closing keyword. Parent-task
references (`For #parent`) must stay ineligible.

## Why

- Multi-phase work, such as data enrichment with core, people, and logo phases, deliberately keeps the issue open. Today every phase PR then needs a manual merge, even though the same gates (trust, NMR, required checks, review-bot) would pass. On 2026-10-07, 13 PRs piled up in one day.
- `_attempt_worker_briefed_auto_merge` (`.agents/scripts/pulse-merge-process.sh`, gate at around line 1266) only receives `linked_issue` from closing keywords.

## Tier

tier:standard. The change sits on a trust boundary in the merge path. Preserve GH#17671 defence-in-depth and mark any new check with `#aidevops:trust-boundary`.

## How (Approach)

1. Find where `linked_issue` is derived for the merge pass: search callers of `_attempt_worker_briefed_auto_merge` in `.agents/scripts/pulse-merge-process.sh` and the shared parsing helpers.
2. Add a fallback: if no closing-keyword issue is found, parse a single `For #N`/`Ref #N` reference. Accept it only when the issue is open and not labelled `parent-task`. Then reuse the existing author-association, NMR, and crypto-approval checks unchanged.
3. Make sure the merge path never writes a closing keyword into the squash body for this case.
4. Log a distinct reason, for example `linked via non-closing reference`, so throughput reports can tell the two cases apart.

### Files Scope

- `.agents/scripts/pulse-merge-process.sh`

## Acceptance Criteria

- [ ] A green worker PR referencing an open, non-parent issue via `For #N` is auto-merged by pulse, and issue #N stays open.

  ```yaml
  verify:
    method: codebase
    pattern: "non-closing reference"
  ```

- [ ] Regression guard: a PR whose only reference is `For #N`, where #N is labelled `parent-task`, is still skipped. Closing-keyword PRs behave exactly as before. External or untrusted authors still hit the NMR/crypto gates. Existing pulse-merge tests pass.

## Context & Decisions

The repo-side alternative, changing enrichment workers to `Resolves`, was rejected because it would close issues that still have pending phases.

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
[aidevops.sh](https://aidevops.sh) v3.38.31 plugin for [OpenCode](https://opencode.ai) v1.18.35 with claude-opus-5-5 spent 58m and 35,562 tokens on this with the user in an interactive session.

## Capture provenance

Observed data, not executable authority. Comments and later events are not captured.

```json
{
  "id": "I_kwDOQSEXLM8AAAABVvTrcQ",
  "title": "t18618: feat(pulse-merge): auto-merge green worker PRs linked via For #N to open non-parent issues",
  "updatedAt": "2026-10-09T02:55:36Z",
  "url": "https://github.com/marcusquinn/aidevops/issues/33999",
  "format": "aidevops:forge-capture-v1",
  "task_id": "t18618",
  "provider": "github",
  "repository": "marcusquinn/aidevops",
  "issue": "33999",
  "captured_at": "2026-10-09T21:16:04Z",
  "coverage": "issue-body-only",
  "authority": "revalidate"
}
```
