# t18148: Terminate cancelled subagents and report bounded side-effect receipts

## Origin

- **Created:** 2026-07-16
- **Session:** auto-detected worker-ready issue body
- **Created by:** brief-readiness-helper (stub — canonical brief lives in issue)
- **Parent issue:** GH#27978
- **Blocked by:** GH#27992

## Canonical Brief

**The authoritative brief for this task is the GitHub issue body:**

https://github.com/marcusquinn/aidevops/issues/27993

The issue body contains all required sections (Task/What, Why, How,
Acceptance, Files to modify) and is the single source of truth.
This stub exists only to satisfy the brief-file-exists gate.

## What

Terminate and reap cancelled children before reporting abort, then return a bounded, redacted side-effect receipt.

## Why

The parent incident reported an aborted task only after local and external mutations had already occurred.

## How

### Files to modify

- `.agents/plugins/opencode-aidevops/index.mjs`
- A focused subagent lifecycle/receipt module
- `.agents/plugins/opencode-aidevops/observability.mjs` only if its storage can be reused safely
- Focused cancellation, runtime-event, and receipt tests named in GH#27993

Implement after GH#27992 establishes reusable child lifecycle identity/state.

## Acceptance Criteria

- Parent abort waits for confirmed child termination/reaping.
- Receipts classify observed attempts/outcomes without secrets or private paths.
- Missing evidence is explicit instead of reported as zero side effects.
