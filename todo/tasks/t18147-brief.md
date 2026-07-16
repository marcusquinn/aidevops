# t18147: Block compaction auto-continue for completed child sessions

## Origin

- **Created:** 2026-07-16
- **Session:** auto-detected worker-ready issue body
- **Created by:** brief-readiness-helper (stub — canonical brief lives in issue)
- **Parent issue:** GH#27978

## Canonical Brief

**The authoritative brief for this task is the GitHub issue body:**

https://github.com/marcusquinn/aidevops/issues/27992

The issue body contains all required sections (Task/What, Why, How,
Acceptance, Files to modify) and is the single source of truth.
This stub exists only to satisfy the brief-file-exists gate.

## What

Refuse automatic compaction continuation for child sessions already completed with a terminal finish state.

## Why

The parent incident resumed a child after `finish=stop`; the current plugin registers compaction context but no auto-continue lifecycle guard.

## How

### Files to modify

- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/compaction.mjs` or a focused extracted lifecycle module
- Focused compaction and runtime-event tests named in GH#27992

Validate the current OpenCode hook payload before implementation and preserve valid primary-session continuation.

## Acceptance Criteria

- Terminal child sessions cannot auto-continue.
- Eligible incomplete primary sessions preserve existing behavior.
- Permission state cannot widen across compaction.
