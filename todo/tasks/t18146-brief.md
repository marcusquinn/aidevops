# t18146: Enforce a no-write research subagent capability profile

## Origin

- **Created:** 2026-07-16
- **Session:** auto-detected worker-ready issue body
- **Created by:** brief-readiness-helper (stub — canonical brief lives in issue)
- **Parent issue:** GH#27978

## Canonical Brief

**The authoritative brief for this task is the GitHub issue body:**

https://github.com/marcusquinn/aidevops/issues/27991

The issue body contains all required sections (Task/What, Why, How,
Acceptance, Files to modify) and is the single source of truth.
This stub exists only to satisfy the brief-file-exists gate.

## What

Provide a mechanically enforced, no-write OpenCode research capability profile and route research-only dispatches through it.

## Why

Prompt text did not prevent the `general` child in parent GH#27978 from editing files and creating external state.

## How

### Files to modify

- `.agents/research.md`
- `.agents/scripts/generate-runtime-config-agents.sh`
- `.agents/plugins/opencode-aidevops/config-hook.mjs`
- Focused generated-agent and plugin permission tests named in the canonical issue

Follow the complete write-surface, compatibility, and verification guidance in GH#27991.

## Acceptance Criteria

- Research reads/searches remain usable.
- Local, Git, nested-task, network-write, and account mutations are denied before side effects.
- Resume/compaction cannot widen the capability envelope.
