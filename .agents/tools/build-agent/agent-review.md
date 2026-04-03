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

- **Trigger**: Session end, user correction, observable failure, fixing multiple issues
- **Process**: Complete task → cite evidence → `rg "pattern" .agents/` (dedup) → propose fix → ask permission
- **Write Restrictions (MANDATORY)**: On `main`/`master` — ALLOWED: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. All other files → propose edits for worktree application.

<!-- AI-CONTEXT-END -->

## Review Checklist

| # | Check | Action if failing |
|---|-------|-------------------|
| 1 | **Instruction count** (~50-100 main, <100 subagent) | Consolidate, move to subagent, or remove |
| 2 | **Universal applicability** (>80% tasks) | Extract task-specific content to subagents |
| 3 | **Duplicate detection** | Single authoritative source per concept |
| 4 | **Code examples** | Keep authoritative; search-pattern reference as supplement only |
| 5 | **AI-CONTEXT block** | Rewrite if an AI would get stuck with only this |
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

## Patterns

- **Consolidate**: Merge redundant rules (e.g., `local var="$1"` for all parameters).
- **Move to subagent**: Replace inline rules with pointers (e.g., `See aidevops/architecture.md`).
- **Replace code with reference**: Use `rg "pattern" .agents/scripts/` + minimal authoritative example; don't remove the example entirely.
