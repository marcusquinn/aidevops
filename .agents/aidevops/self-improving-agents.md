---
description: Self-improving agent system for continuous enhancement
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Self-Improving Agent System

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Principle**: AGENTS.md "Self-Improvement" section — universal for every agent session
- **Mechanism**: Pulse Step 2a outcome observation + `/remember`/`/recall` + GitHub issues
- **Status**: `self-improve-helper.sh` is archived; self-improvement is behaviour, not a standalone tool

<!-- AI-CONTEXT-END -->

## Current Model

Self-improvement is a universal principle for interactive, worker, and supervisor sessions. The authoritative rules live in AGENTS.md and `reference/self-improvement.md`.

### Observe existing state

- `TODO.md`, `todo/PLANS.md`, and GitHub issues/PRs are the state database
- Pulse Step 2a checks stale PRs (6h+ without progress), closed-without-merge PRs, and duplicate work
- Workers observe their own outcomes and store reusable patterns via `/remember`

### Respond with a GitHub issue

When a systemic problem appears, create a GitHub issue instead of adding a workaround:

```bash
gh issue create --repo <owner/repo> \
  --title "Pattern: <description of systemic problem>" \
  --body "Observed: <evidence>. Root cause hypothesis: <theory>. Proposed fix: <action>." \
  --label "bug,priority:high"
```

### What counts as self-improvement

- Filing issues for repeated failure patterns
- Improving agent prompts when workers consistently misunderstand instructions
- Identifying missing automation (for example, a manual step that should be a `gh` command)
- Flagging stale tasks that are blocked but not marked as such

### Record and reuse patterns

```bash
# After a successful approach
/remember "SUCCESS: structured debugging found root cause for bugfix (sonnet, 120s)"

# After a failure
/remember "FAILURE: architecture design with sonnet — needed opus for cross-service trade-offs"

# Recall relevant patterns
/recall "bugfix patterns"
```

## Archived Script

`self-improve-helper.sh` (773 lines) used a 4-phase cycle (analyze → refine → test → PR) with OpenCode server sessions. It was replaced by:

1. AGENTS.md "Self-Improvement" — universal session behaviour
2. Pulse Step 2a — outcome observation from GitHub state
3. Cross-session memory — `/remember` and `/recall`
4. GitHub issues — trackable fixes instead of local workarounds

Archived reference: `scripts/archived/self-improve-helper.sh`

## Related Documentation

- AGENTS.md "Self-Improvement" section
- `reference/self-improvement.md`
- `scripts/commands/pulse.md`
- `reference/memory.md`
- `tools/security/privacy-filter.md`
