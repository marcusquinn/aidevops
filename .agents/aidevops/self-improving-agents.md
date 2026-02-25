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

- **Principle**: AGENTS.md "Self-Improvement" section — universal for all agents
- **Mechanism**: Pulse supervisor outcome observation (Step 2a) + agent `/remember` + GitHub issues
- **No dedicated script**: The `self-improve-helper.sh` has been archived. Self-improvement is now a universal agent behaviour, not a separate tool.

<!-- AI-CONTEXT-END -->

## How Self-Improvement Works Now

Self-improvement is a **universal principle** embedded in every agent session — interactive, worker, or supervisor. It is defined in AGENTS.md "Self-Improvement" section and does not require a dedicated script.

### Observation

Every agent observes outcomes from existing state:

- **TODO.md, PLANS.md, and GitHub issues/PRs** are the state database
- **Pulse Step 2a** checks for stale PRs (6h+ no progress), repeated failures (closed-without-merge PRs), and duplicate work
- **Workers** observe their own outcomes and record patterns via `/remember`

### Response

When a systemic problem is observed, the response is to **create a GitHub issue**, not a workaround:

```bash
gh issue create --repo <owner/repo> \
  --title "Pattern: <description of systemic problem>" \
  --body "Observed: <evidence>. Root cause hypothesis: <theory>. Proposed fix: <action>." \
  --label "bug,priority:high"
```

### What Counts as Self-Improvement

- Filing issues for repeated failure patterns
- Improving agent prompts when workers consistently misunderstand instructions
- Identifying missing automation (e.g., a manual step that could be a `gh` command)
- Flagging stale tasks that are blocked but not marked as such

### Recording Patterns

Agents record learnings via cross-session memory:

```bash
# After a successful approach
/remember "SUCCESS: structured debugging found root cause for bugfix (sonnet, 120s)"

# After a failure
/remember "FAILURE: architecture design with sonnet — needed opus for cross-service trade-offs"

# Recall relevant patterns
/recall "bugfix patterns"
```

## Why the Script Was Archived

The `self-improve-helper.sh` (773 lines) implemented a 4-phase cycle (analyze → refine → test → PR) using OpenCode server sessions. This has been replaced by:

1. **AGENTS.md "Self-Improvement" section** — every agent session improves the system as a universal principle
2. **Pulse Step 2a** — observes outcomes from GitHub state (stale PRs, failures, duplicates)
3. **Cross-session memory** — agents record patterns via `/remember` and `/recall`
4. **GitHub issues** — systemic problems become trackable tasks, not workarounds

The archived script is at `scripts/archived/self-improve-helper.sh` for reference.

## Related Documentation

- AGENTS.md "Self-Improvement" section — the authoritative definition
- `scripts/commands/pulse.md` — supervisor outcome observation (Step 2a)
- `memory/README.md` — cross-session memory system
- `tools/security/privacy-filter.md` — privacy filter for PRs
