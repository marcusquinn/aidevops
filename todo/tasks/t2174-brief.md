<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2174: opencode DB maintenance routine

## Origin

- **Created:** 2026-04-18
- **Session:** claude-code:t2174-opencode-db-maintenance
- **Created by:** ai-interactive (user-directed)
- **Conversation context:** User reported recurring "database is locked" errors in opencode even with a single active session. Diagnostic found 10 opencode processes holding 20+ FDs on a 1.3 GB DB, with live log evidence of a `+5015ms database is locked` error from `session.processor` — confirming busy_timeout=5000ms is being honored but writers hold the lock longer than 5s, especially on large tool outputs (anomalyco/opencode#21000 pattern).

## What

A new `r913 Weekly opencode DB maintenance` core routine plus its helper script `opencode-db-maintenance-helper.sh`. The helper runs `wal_checkpoint(TRUNCATE)`, `PRAGMA optimize`, and a conditional `VACUUM` to keep opencode's SQLite DB compact and the WAL truncated — minimising lock-hold times under concurrent session load. Ships via `aidevops update` so every user benefits; silent no-op on systems without opencode installed.

## Why

opencode's SQLite DB accumulates 1 GB+ of session state over weeks of active use. Combined with SQLite WAL's single-writer constraint and opencode's multi-connection-per-process pattern, long write transactions (e.g., large bash tool outputs) hold the writer lock beyond the compiled 5s busy_timeout, surfacing as session-halting "database is locked" errors.

The architectural fix (sharding, retry-with-backoff) lives upstream in anomalyco/opencode and is tracked in #21215, #21000, #20935, #21579 — all open. Until those land, smaller DB = shorter lock windows = fewer failures. A weekly off-hours VACUUM is the standard SQLite maintenance pattern and can be shipped without any upstream changes.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — No, this is a new feature: new helper script + new test + core-routines entry + advisory + reference doc + brief + TODO update (6 files). Standard.
- [x] **Judgment-free?** — No, this needs VACUUM threshold tuning, throttle logic, process-detection safety.
- [x] **Estimate 1h or less?** — No, ~3h total (helper + tests + docs).

**Selected tier:** `tier:standard`

**Tier rationale:** Multi-file implementation with safety gating, environment-var configuration, and OS-specific integration. Sonnet-class work, not Haiku.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/opencode-db-maintenance-helper.sh` — the helper with subcommands `check`, `report`, `maintain [--force]`, `auto`, `help`. Models on `.agents/scripts/worktree-helper.sh` style and uses shared-constants.sh for colours.
- `NEW: .agents/scripts/tests/test-opencode-db-maintenance.sh` — sandbox-based tests (synthetic SQLite DB in tmp dir via XDG_DATA_HOME redirect). 11 assertions.
- `EDIT: .agents/scripts/routines/core-routines.sh` — two changes: append r913 line in `get_core_routine_entries`, add `describe_r913()` function mirroring the existing r906 (calendar-scheduled) pattern.
- `NEW: .agents/reference/opencode-maintenance.md` — user-facing docs covering the problem, the routine, subcommands, config, safety, and what we can't fix from outside opencode.
- `EDIT: TODO.md` — add t2174 entry with `ref:GH#<NNN>`.

No advisory file — `aidevops update`'s existing `_create_core_routine_issues` path (non-interactive setup → `setup_routines` → `detect_and_create_all` → `init_personal` → `_create_core_routine_issues`) is idempotent and seeds every core routine's tracking issue into the user's routines repo, including newly-added ones like r913. Existing users get r913 automatically on the next auto-update; no user action required.

### Implementation Steps

1. Helper script with subcommands (see `.agents/scripts/opencode-db-maintenance-helper.sh` for full implementation). Key design points:
   - Silent no-op if opencode not installed (so other users see no noise).
   - Refuses to run with active `opencode-ai/bin/.opencode` processes unless `--force`.
   - VACUUM only triggers if DB > 500 MB OR free-page fraction > 10%.
   - Auto mode throttles to once per 6 days via `last-run.json`.
   - State under `~/.aidevops/.agent-workspace/work/opencode-maintenance/`.

2. Register as r913 in `core-routines.sh` so new users get it automatically via `setup_routines` → `_create_core_routine_issues`. Existing users get the advisory.

3. Test harness uses sandbox DB + `HOME` redirect so tests don't touch real state. `--force` is used because the host may have real opencode running.

### Verification

```bash
# Shellcheck clean
shellcheck .agents/scripts/opencode-db-maintenance-helper.sh
shellcheck .agents/scripts/tests/test-opencode-db-maintenance.sh
shellcheck .agents/scripts/routines/core-routines.sh

# Tests pass
.agents/scripts/tests/test-opencode-db-maintenance.sh
# Expected: "Results: 11 passed, 0 failed"

# r913 registered
bash -c "source .agents/scripts/routines/core-routines.sh && get_core_routine_entries | grep r913"

# Helper smoke test
.agents/scripts/opencode-db-maintenance-helper.sh help
.agents/scripts/opencode-db-maintenance-helper.sh check
.agents/scripts/opencode-db-maintenance-helper.sh report
```

## Acceptance Criteria

- [x] `opencode-db-maintenance-helper.sh` exists with `check`, `report`, `maintain`, `auto`, `help` subcommands
- [x] `shellcheck` clean on helper, test, and core-routines.sh
- [x] Test harness passes 11/11 assertions
- [x] r913 is emitted by `get_core_routine_entries`
- [x] `describe_r913` is defined and outputs markdown for both darwin and linux
- [x] Helper is a silent no-op when opencode is not installed (exit 0, no output on `auto`)
- [x] Helper refuses `maintain` when opencode processes are active without `--force` (exit 2)
- [x] Reference doc explains the problem, mitigation, and architectural limits

## Context & Decisions

- **Silent no-op over hard failure.** The routine ships as a core routine for ALL users, including those who don't use opencode. Rather than gating it behind detection in `setup_routines`, the helper itself exits 0 cleanly when opencode isn't installed. Keeps the routines list uniform across users.
- **Process-active refusal is the default.** VACUUM conflicts with live writers. Defaulting to refuse-unless-forced prevents the maintenance routine from itself causing the errors it's trying to reduce.
- **VACUUM is conditional.** VACUUM rewrites the whole DB file — expensive on 1+ GB databases. Triggering only when fragmentation is meaningful (>10% free pages) or size is large (>500 MB) keeps the routine cheap for users whose DBs never get big.
- **We cannot fix `busy_timeout` externally.** PRAGMAs are per-connection in SQLite; only opencode's own code can set them at connection open. The reference doc documents this boundary so users don't expect the routine to solve problems it can't.
- **No advisory — auto-update already handles it.** `aidevops update`'s non-interactive path runs `_create_core_routine_issues` idempotently on every update, so existing users get r913's tracking issue seeded automatically. Advisories are only needed for changes that require manual user action; adding a new core routine doesn't.
- **Upstream PR work is complementary, not a replacement.** The user already filed anomalyco/opencode#21215; the routine is a holding pattern until sharding lands.

## Relevant Files

- `.agents/scripts/worktree-helper.sh` — helper-script style reference
- `.agents/scripts/routines/core-routines.sh:412-450` — r906 is the closest-pattern calendar-scheduled routine to model r913 on
- `.agents/scripts/init-routines-helper.sh:783-796` — how `_create_core_routine_issues` seeds tracking issues for new routines
- `.agents/advisories/litellm-2026-03.advisory` — advisory format reference
- anomalyco/opencode#21215 — upstream issue the routine is addressing

## Dependencies

- **Blocked by:** none
- **Blocks:** none (independent mitigation)
- **External:** sqlite3 CLI (ships with macOS/Linux by default)

## Estimate Breakdown

| Phase | Time | Notes |
|---|---|---|
| Helper design + implementation | 1h | Subcommand routing, PRAGMA logic, safety gates |
| Tests | 30m | Sandbox setup, 11 assertions |
| core-routines.sh integration | 15m | Entry + describe function |
| Advisory + reference doc | 45m | User-facing explanation |
| Verification + shellcheck fixes | 30m | Lint and smoke tests |
| **Total** | **~3h** | |
