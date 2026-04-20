<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Brief Composition Agent — Routing

When to use this agent for structured GitHub content.

## Work item creation (dispatched to workers)

| Creator | Content type | What this agent provides |
|---------|-------------|------------------------|
| `/define` | Task brief | Tier classification + prescriptive format |
| `/new-task` | Task brief + issue body | Brief structure + issue body format |
| `/save-todo` | Task brief | Brief structure from conversation |
| `code-simplifier` | Simplification issue | Prescriptive oldString/newString findings |
| `quality-feedback-helper.sh` | Review feedback issue | Exact code suggestions as edit blocks |
| `pulse-wrapper.sh` | Complexity scan issue | Scan finding → structured issue body |
| `framework-routing-helper.sh` | Framework issue | Finding → structured issue body |

## Comments (context for workers and humans)

| Creator | Content type | What this agent provides |
|---------|-------------|------------------------|
| `pulse-wrapper.sh` | Dispatch comment | Structured context: what to implement, where, why |
| `worker-lifecycle-common.sh` | Kill/escalation comment | Structured escalation report with reason codes |
| `triage-review.md` | Review comment | Tier assessment + actionable implementation guidance |
| Workers (on completion) | PR description | Summary + linked issue + verification evidence |
| Workers (on failure) | Escalation comment | What was tried, where it stuck, brief gaps |

## Discovery-pass routing (t2409)

When the pre-composition discovery pass (see `workflows/brief.md` "Pre-composition Checks") surfaces hits on the target files, route the task through one of these paths instead of composing a new brief:

| Discovery result | Route | Action |
|-----------------|-------|--------|
| **Already-shipped**: merged PR touches target file + symbol | Close-with-pointer | Close the issue with a comment: "Already fixed in PR #NNN (commit `<sha>`) — verified `<symbol>` at `<file>:<line>` matches the fix." Do NOT file a new task. |
| **In-flight collision**: open PR touches target files | Comment on open PR | Post a comment on the open PR noting the overlap: "GH#NNN also targets `<file>` — coordinate to avoid conflicts." Do NOT file a competing task. |
| **Stale issue**: merged PR shipped the fix but issue is still open | Close stale issue | Close the issue with: "Resolved by PR #NNN (merged `<date>`). Verified against current HEAD." |
| **Partial overlap**: merged/open PR touches one of N target files | Compose brief with note | Proceed with brief composition but include a "Collision Risk" note in the Context section: "PR #NNN touches `<file>` — rebase after that PR merges." |

**Decision rule**: if the discovery pass surfaces a prior landed fix on the exact file + symbol you intended to change, STOP and verify whether the bug is still reproducible against the new code before continuing. Often the fix is already in place and the issue is stale.

## PR descriptions

| Creator | Content type | What this agent provides |
|---------|-------------|------------------------|
| `/full-loop` workers | PR body | Summary, linked issue (`Closes #NNN`), verification |
| Interactive sessions | PR body | Summary, motivation, testing evidence |
