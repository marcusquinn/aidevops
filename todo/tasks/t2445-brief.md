# t2445: Create scope-guard-pre-push.sh hook

## Origin

- **Created:** 2026-04-20
- **Session:** headless worker for GH#20148
- **Parent task:** t2264 (GH#19808)

## What

Create `.agents/hooks/scope-guard-pre-push.sh` — pre-push hook that blocks pushes modifying files outside the brief's `files_scope`.

## Why

Prevents silent rebase-introduced scope creep (the root cause of #19808).

## How

- NEW: `.agents/hooks/scope-guard-pre-push.sh` — model on `.agents/hooks/privacy-guard-pre-push.sh`

## Acceptance

- Hook blocks out-of-scope files, passes in-scope files, and prevents path traversal (resolved real path must be within repo root)
- `SCOPE_GUARD_DISABLE=1` bypass works
- Missing brief = fail-open; Missing `## Files Scope` section in existing brief = fail-closed
- `shellcheck` passes

## Tier

Selected tier: `tier:standard`

Ref #19808
Blocked by: t2444
