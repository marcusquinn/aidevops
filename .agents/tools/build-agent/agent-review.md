---
description: Systematic review and improvement of agent instructions
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agent Review

<!-- AI-CONTEXT-START -->

**Trigger**: Session end, user correction, observable failure, periodic maintenance.
**Self-Assessment**: Observe failure → complete task → cite evidence → search for `"pattern"` under `.agents/` with Grep → propose fix → ask permission.
**Exact Search**: Use the Grep tool for content searches; when Bash is available, `rg "pattern" <path>` is an optional equivalent.
**Write Restrictions (MANDATORY)**: Interactive sessions use a linked worktree for every edit, including planning files. Headless bookkeeping and explicitly planning-only workers may use only the narrow `main`/`master` exception enforced by `pre-edit-check.sh`; all other headless edits require a linked worktree. Follow `workflows/pre-edit.md` rather than copying its path allowlist here.

<!-- AI-CONTEXT-END -->

## Review Checklist

| # | Check | Action if failing |
|---|-------|-------------------|
| 1 | **Instruction count** (~50-100 per agent; maintainability heuristic) | Investigate load; counts are heuristics, never standalone removal evidence |
| 2 | **Universal applicability** (>80% tasks) | Investigate whether a reliable task-specific trigger supports extraction |
| 3 | **Duplicate detection** (Grep for `"pattern"` under `.agents/`) | Classify exact duplicates vs boundary reinforcement or variants |
| 4 | **Code examples** (authoritative/working) | Keep only when authoritative; otherwise use Grep references for `"pattern"` under `.agents/scripts/` or stable section headings |
| 5 | **AI-CONTEXT block** (standalone essentials) | Rewrite if an AI would get stuck with only this |
| 6 | **Slash commands** | Move to `scripts/commands/` or domain subagent |

Before consolidating, relocating, or removing a directive, recover the protected failure/rationale from nearby task IDs, issue/PR context, and recent file history. Record its current enforcement or routing, and distinguish exact duplication from reinforcement at another decision boundary, runtime-specific variants, and similar-but-different hazards. Relocation must name the reliable trigger that delivers the lesson at its decision point. Removal requires evidence that the knowledge is obsolete or fully superseded and identifies any mechanism that preserves or enforces it.

## Improvement Proposal Format

```markdown
## Agent Improvement Proposal
**File**: `.agents/[path]/[file].md`
**Issue**: [Description]
**Evidence**: [Failure, contradiction, or feedback]
**Provenance**: [Protected failure/rationale and recent history inspected]
**Related Files**: `.agents/[other-file].md` (checked for duplicates)
**Proposed Change**: [Specific before/after]
**Boundary Analysis**: [Exact duplicate, reinforcement, runtime variant, or similar-but-different hazard]
**Delivery/Preservation**: [Reliable relocation trigger or superseding enforcement mechanism]
**Verification**: [How retained behaviour and routing were tested]
**Impact**: [ ] No conflicts [ ] Instruction count (diagnostic): [+/- N] [ ] Tested
```

## Review Categories

When flagging code issues, use the structured categories in `tools/code-review/review-categories.md` for consistent severity assignment. Categories include: `commit-message-mismatch`, `instruction-file-disobeyed`, `fails-silently`, `security-violation`, `logic-error`, `runtime-error-risk`, and 8 others — each with examples, exceptions, and CRITICAL/MAJOR/MINOR/NITPICK severity guidance.

## Contributing

Create proposal → edit in `~/Git/aidevops/` → run `.agents/scripts/linters-local.sh` → commit/PR. Ref: `workflows/release.md`.
