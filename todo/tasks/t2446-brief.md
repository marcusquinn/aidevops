# t2446: Integrate scope guard into install-pre-push-guards.sh

## Origin

- **Created:** 2026-04-20
- **Session:** headless worker for GH#20148
- **Parent task:** t2264 (GH#19808)

## What

Add `--guard scope` support to `.agents/scripts/install-pre-push-guards.sh`. Update documentation.

## Why

Scope guard needs the same install/uninstall/status management as the privacy and complexity guards.

## How

- EDIT: `.agents/scripts/install-pre-push-guards.sh` — add scope guard registration
- EDIT: `.agents/AGENTS.md` — document scope guard

## Acceptance

- `install-pre-push-guards.sh install --guard scope` works
- `install-pre-push-guards.sh status` reports scope guard
- `shellcheck` passes

## Tier

Selected tier: `tier:standard`

Ref #19808
Blocked by: t2445
