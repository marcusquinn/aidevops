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

## Quick Reference

- **Purpose**: Systematic review and improvement of agent instructions
- **Trigger**: Session end, user correction, observable failure, periodic maintenance
- **Output**: Proposed improvements with evidence and scope
- **Checklist**: Instruction count · Universal applicability · Duplicate detection · Code examples · AI-CONTEXT block · Slash commands (see table below)
- **Self-Assessment**: User correction, command/path failure, contradiction, staleness → complete task → cite evidence → `rg "pattern" .agents/` → propose fix → ask permission
- **Write Restrictions (MANDATORY)**: On `main`/`master` — ALLOWED: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. BLOCKED: all other files. Code changes → return proposed edits for worktree application.

<!-- AI-CONTEXT-END -->

## Review Checklist

| # | Check | Action if failing |
|---|-------|-------------------|
| 1 | **Instruction count** (~50-100 main, <100 subagent) | Consolidate, move to subagent, or remove |
| 2 | **Universal applicability** (>80% tasks) | Extract task-specific content to subagents |
| 3 | **Duplicate detection** (`rg "pattern" .agents/`) | Single authoritative source per concept |
| 4 | **Code examples** (authoritative/working) | Keep authoritative examples; search-pattern reference as supplement only |
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

## Common Improvement Patterns

- **Consolidating**: Merge redundant rules (e.g., `local var="$1"` for all parameters).
- **Moving to subagent**: Replace inline rules with pointers (e.g., `See aidevops/architecture.md`).
- **Replacing code with reference**: Pair `rg "pattern" .agents/scripts/` with minimal authoritative examples, not as a full replacement.

## Contributing

Create proposal → edit in `~/Git/aidevops/` → run `.agents/scripts/linters-local.sh` → commit/PR. Ref: `workflows/release.md`.
