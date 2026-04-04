---
description: Self-improving agent system for continuous enhancement
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Self-Improving Agent System

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Principle**: AGENTS.md "Self-Improvement" section — universal for every agent session
- **Mechanism**: Pulse Step 2a outcome observation + `/remember`/`/recall` + GitHub issues
- **Full rules**: `reference/self-improvement.md`
- **Status**: `self-improve-helper.sh` is archived; self-improvement is behaviour, not a standalone tool

<!-- AI-CONTEXT-END -->

## What counts as self-improvement

- Filing issues for repeated failure patterns
- Improving agent prompts when workers consistently misunderstand instructions
- Identifying missing automation (manual steps that should be `gh` commands)
- Flagging stale tasks that are blocked but not marked as such

## Observe existing state

- `TODO.md`, `todo/PLANS.md`, and GitHub issues/PRs are the state database
- Pulse Step 2a checks stale PRs (6h+ without progress), closed-without-merge PRs, and duplicate work
- Workers observe their own outcomes and store reusable patterns via `/remember`

## Respond with a GitHub issue

When a systemic problem appears, create a GitHub issue instead of adding a workaround:

```bash
gh issue create --repo <owner/repo> \
  --title "Pattern: <description of systemic problem>" \
  --body "Observed: <evidence>. Root cause hypothesis: <theory>. Proposed fix: <action>." \
  --label "bug,priority:high"
```

## Record and reuse patterns

```bash
# After a successful approach
/remember "SUCCESS: structured debugging found root cause for bugfix (sonnet, 120s)"

# After a failure
/remember "FAILURE: architecture design with sonnet — needed opus for cross-service trade-offs"

# Recall relevant patterns
/recall "bugfix patterns"
```

## Related

- `reference/self-improvement.md` — full rules and routing
- `scripts/commands/pulse.md`
- `reference/memory.md`
