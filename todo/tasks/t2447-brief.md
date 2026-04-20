# t2447: Regression test for rebase-introduced scope creep detection

## Origin

- **Created:** 2026-04-20
- **Session:** headless worker for GH#20148
- **Parent task:** t2264 (GH#19808)

## What

Create `.agents/scripts/tests/test-scope-guard-pre-push.sh` — regression test validating the scope guard blocks out-of-scope rebase artifacts.

## Why

Without a regression test, the scope guard itself could regress silently.

## How

- NEW: `.agents/scripts/tests/test-scope-guard-pre-push.sh` — model on existing test fixtures

## Acceptance

- Test covers: in-scope pass, out-of-scope block, bypass, missing brief, missing section
- Uses temporary repos (no side effects)
- `shellcheck` and `bash` execution pass

## Tier

Selected tier: `tier:standard`

Ref #19808
Blocked by: t2445
