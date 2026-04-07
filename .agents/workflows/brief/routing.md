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

## PR descriptions

| Creator | Content type | What this agent provides |
|---------|-------------|------------------------|
| `/full-loop` workers | PR body | Summary, linked issue (`Closes #NNN`), verification |
| Interactive sessions | PR body | Summary, motivation, testing evidence |
