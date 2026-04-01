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

**Review Checklist**: (1) Instruction count — over budget? (2) Universal applicability — task-specific content? (3) Duplicate detection — same guidance elsewhere? (4) Code examples — still accurate/authoritative? (5) AI-CONTEXT block — captures essentials? (6) Slash commands — defined inline instead of `scripts/commands/`?

**Self-Assessment Triggers**: User corrects response, commands/paths fail, contradiction with authoritative sources, staleness (versions, deprecated APIs).

**Process**: Complete task first, cite evidence, check duplicates (`rg "pattern" .agents/`), propose specific fix, ask permission.

**Write Restrictions (MANDATORY)**: On `main`/`master` — ALLOWED: `README.md`, `TODO.md`, `todo/PLANS.md`, `todo/tasks/*`. BLOCKED: all other files. For code changes: return proposed edits to calling agent for worktree application.

<!-- AI-CONTEXT-END -->

## When to Review

Suggest `@agent-review` at session end, after user corrections, observable failures, or fixing multiple issues. See `workflows/session-manager.md` for full session lifecycle.

## Review Checklist

| # | Check | Action if failing |
|---|-------|-------------------|
| 1 | **Instruction count** — <50 main, <100 subagent | Consolidate, move to subagent, or remove |
| 2 | **Universal applicability** — >80% of tasks? | Extract task-specific content to subagents |
| 3 | **Duplicate detection** — `rg "pattern" .agents/` | Single authoritative source per concept |
| 4 | **Code examples** — authoritative, working, secrets placeholder'd? | Replace with search-pattern reference if possible |
| 5 | **AI-CONTEXT block** — captures essentials standalone? | Rewrite if an AI would get stuck with only this |
| 6 | **Slash commands** — defined inline in main agents? | Move to `scripts/commands/` or domain subagent |

## Improvement Proposal Format

```markdown
## Agent Improvement Proposal

**File**: `.agents/[path]/[file].md`
**Issue**: [Brief description]
**Evidence**: [Specific failure, contradiction, or user feedback]
**Related Files** (checked for duplicates): `.agents/[other-file].md` - [relationship]
**Proposed Change**: [Specific before/after or description]
**Impact**: [ ] No conflicts with other agents [ ] Instruction count: [+/- N] [ ] Tested if code example
```

## Common Improvement Patterns

**Consolidating instructions** — merge redundant rules into one:

```markdown
# Before (5 instructions): Use local variables / Assign parameters to locals / Never use $1 directly / Pattern: local var="$1" / This prevents issues
# After (1 instruction): Pattern: `local var="$1"` for all parameters
```

**Moving to subagent** — replace 50 lines of inline rules with `See aidevops/architecture.md for schema guidelines`, move detail to subagent file.

**Replacing code with reference** — replace inline code blocks with `rg "error handling" .agents/scripts/` (use search patterns, not line numbers — they drift).

## Contributing

Create proposal → make changes in `~/Git/aidevops/` → run `.agents/scripts/linters-local.sh` → commit and create PR. See `workflows/release-process.md`.
