<!-- aidevops:brief-schema=v2 -->

# t19017: fix(opencode-db-archive): an archive-DB event-expiry deferral must not skip the live-DB session move

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (aidevops productivity mission, parent t19002 / GH#38332)
- **Conversation context:** Found while diagnosing a 62 GB live `opencode.db` whose hourly archive had not completed in more than 72 hours (21 consecutive deferrals).

## What

In `cmd_archive`, a deferral from the optional archived-event expiry pass (`_archive_expire_events` returns 2 when `opencode-archive.db` has any holder) should skip only the expiry. The primary work, moving eligible sessions out of the live DB, should still run. The command keeps returning 2 overall so the async scheduler still treats the pass as incomplete and retries.

## Why

`.agents/scripts/opencode-db-archive.sh` `cmd_archive` (around line 1175) runs `_archive_expire_events ... || return $?`. Any reader of the archive DB therefore cancels the whole live-DB archive for that cycle. Examples are the profile README model-usage query (`ATTACH ... AS archive`), session-time scans and session lookups. Evidence in `~/.aidevops/logs/opencode-db-archive.log` at 2026-11-15T03:00Z: `Archive event expiry deferred — archive holder state is active or unknown`, then `rc=2` for the main DB, with no retention, preflight or batch lines. That cycle never reached the session move.

The session move itself does not check archive-DB holders. Only `_archive_mutation_preflight` gates the active DB, and SQLite WAL allows a write while readers are attached. Blocking the move on archive-DB readers is therefore stricter than the move needs and inconsistent with its own checks.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** One control-flow change in one function, covered by an existing suite.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/opencode-db-archive.sh` — in `cmd_archive`, capture the expiry rc. Return immediately for rc 1 or 3 (errors). For rc 2, continue to `_archive_mutation_preflight` and the move. At the end, if the move path returned 0 and expiry returned 2, return 2. With `--events-only`, return the expiry rc unchanged.
- `EDIT: .agents/scripts/tests/test-opencode-db-archive.sh` — only if an existing case asserts the old early return. Adjust that assertion. Add no new harness.

### Verification

```bash
shellcheck -x -P .agents/scripts .agents/scripts/opencode-db-archive.sh
bash .agents/scripts/tests/test-opencode-db-archive.sh
# Runtime: after deploy, an archive cycle that logs "Archive event expiry
# deferred" for a DB still logs its Retention/batch lines for that same DB.
```

### Files Scope

- `.agents/scripts/opencode-db-archive.sh`
- `.agents/scripts/tests/test-opencode-db-archive.sh`

## Acceptance Criteria

- [ ] An expiry deferral (rc 2) no longer prevents the session move in the same invocation.
- [ ] The overall rc remains 2 when expiry was deferred, so the scheduler does not record a complete pass.
- [ ] Expiry errors (rc 1 or 3) still stop the command.
- [ ] The existing archive test suite passes.

## Context & Decisions

- Low frequency: 10 occurrences across the whole archive log. The main trigger, the hours-long profile README query, was fixed by t19016 / PR #38427. Other archive-DB readers remain, so the coupling is still worth removing.
- Not in scope: the live DB's 90-day interactive retention (filed separately) and the 60 s per-DB budget.
