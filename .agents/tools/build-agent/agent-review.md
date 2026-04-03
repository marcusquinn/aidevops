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

# Agent Review

<!-- AI-CONTEXT-START -->

**Trigger**: Session end, user correction, observable failure, periodic maintenance.
**Self-Assessment**: Observe failure → complete task → cite evidence → `rg "pattern" .agents/` → propose fix → ask permission.
**Write Restrictions (MANDATORY)**: On `main`/`master` — ALLOWED: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. BLOCKED: all other files. Code changes → return proposed edits for worktree application.

<!-- AI-CONTEXT-END -->

## Review Checklist

| # | Check | Action if failing |
|---|-------|-------------------|
| 1 | **Instruction count** (~50-100 main, <100 subagent) | Consolidate, move to subagent, or remove |
| 2 | **Universal applicability** (>80% tasks) | Extract task-specific content to subagents |
| 3 | **Duplicate detection** (`rg "pattern" .agents/`) | Single authoritative source per concept |
| 4 | **Code examples** (authoritative/working) | Keep; supplement with `rg "pattern" .agents/scripts/` references |
| 5 | **AI-CONTEXT block** (standalone essentials) | Rewrite if an AI would get stuck with only this |
| 6 | **Slash commands** | Move to `scripts/commands/` or domain subagent |

## Improvement Proposal Format

```markdown
## Agent Improvement Proposal
**File**: `.agents/[path]/[file].md`
**Issue**: [Description]
**Evidence**: [Failure, contradiction, or feedback]
**Related Files**: `.agents/[other-file].md` (checked for duplicates)
**Proposed Change**: [Specific before/after]
**Impact**: [ ] No conflicts [ ] Instruction count: [+/- N] [ ] Tested
```

## Review Categories

When flagging code issues, use the structured categories in `tools/code-review/review-categories.md` for consistent severity assignment. Categories include: `commit-message-mismatch`, `instruction-file-disobeyed`, `fails-silently`, `security-violation`, `logic-error`, `runtime-error-risk`, and 8 others — each with examples, exceptions, and CRITICAL/MAJOR/MINOR/NITPICK severity guidance.

## Contributing

Create proposal → edit in `~/Git/aidevops/` → run `.agents/scripts/linters-local.sh` → commit/PR. Ref: `workflows/release.md`.
