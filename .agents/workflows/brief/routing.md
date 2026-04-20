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

## Already-Shipped Detection

When the pre-composition discovery pass (see `workflows/brief.md` "Pre-composition checks") surfaces a **merged PR** that touched the exact target files:

| Signal | Action |
|--------|--------|
| Merged PR fixes the same bug/gap | Close the issue with a pointer: `Duplicate of #NNN (merged <date>). Verified against HEAD — symptom no longer reproduces.` |
| Merged PR partially addresses | File a narrower follow-up task scoped only to the remaining gap. Reference the merged PR in the brief. |
| Merged PR is unrelated (coincidental file overlap) | Proceed with brief composition. Note the overlap in the brief's Context section to save the worker re-checking. |

## In-Flight Collision Detection

When the discovery pass surfaces an **open PR** on the same target files:

| Signal | Action |
|--------|--------|
| Open PR covers the same scope | Post a comment on the open PR with the new requirement. Do NOT file a duplicate task. |
| Open PR partially overlaps | Coordinate: file the new task with a `blocked-by:` reference to the open PR, or scope the new task to non-overlapping files. |
| Open PR is unrelated (coincidental file overlap) | Proceed. Note the in-flight PR in the brief's Context section. |

Both detection paths are mandatory when the discovery pass returns hits. Skipping them is how duplicate PRs get filed (see t2046 "Pre-implementation discovery" for the root cause and evidence).

## PR descriptions

| Creator | Content type | What this agent provides |
|---------|-------------|------------------------|
| `/full-loop` workers | PR body | Summary, linked issue (`Closes #NNN`), verification |
| Interactive sessions | PR body | Summary, motivation, testing evidence |
