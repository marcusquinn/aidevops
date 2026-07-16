# t18149: Require trusted authorization for account-level GitHub CLI mutations

## Origin

- **Created:** 2026-07-16
- **Session:** auto-detected worker-ready issue body
- **Created by:** brief-readiness-helper (stub — canonical brief lives in issue)
- **Parent issue:** GH#27978

## Canonical Brief

**The authoritative brief for this task is the GitHub issue body:**

https://github.com/marcusquinn/aidevops/issues/27994

The issue body contains all required sections (Task/What, Why, How,
Acceptance, Files to modify) and is the single source of truth.
This stub exists only to satisfy the brief-file-exists gate.

## What

Require content-bound trusted authorization for account-level GitHub CLI mutations such as repository fork creation.

## Why

Generic Bash permission allowed the research child in GH#27978 to create a public fork under the operator account.

## How

### Files to modify

- `.agents/configs/command-policy.json`
- Narrow modules under `.agents/scripts/command_policy_*.py`
- OpenCode quality-hook backstop only if required by current architecture
- Command-policy and plugin tests named in GH#27994

Preserve read-only GitHub CLI and ordinary local Git behavior while failing closed on ambiguous account-write parsing.

## Acceptance Criteria

- Untrusted account-level GitHub mutations are denied before network activity.
- Exact trusted authorization permits only the approved operation.
- Direct, wrapped, quoted, and malformed command forms cannot bypass the gate.
