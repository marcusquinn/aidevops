# t19056: fix(opencode-db-archive): persist batch adaptation across runs so the shared DB archive and worker-event expiry stop livelocking

**Task ID:** `t19056` | **Issue:** GH#38590

## Origin

Interactive session (productivity mission), from diagnosing host saturation and repeated archive deferrals on one macOS host. The shared OpenCode DB has not archived a session since 2026-10-23, and the GH#38491 worker-event expiry (released in v3.39.210) has never expired an event there.

Evidence (2026-11-16, read-only queries plus `~/.aidevops/logs/opencode-db-archive.log`, attributed per active DB):

- Shared `opencode.db` is 72.25 GB; `opencode-archive.db` is 31.9 GB.
- Since 2026-10-23T23:00Z: 176 runs reached the shared DB, 67 printed `Found N sessions eligible`, 0 printed `Archived N/M sessions`, 59 ended with `Terminated: 15 sqlite3 "$ACTIVE_DB" <<BATCH_SQL` (the per-DB deadline killed the first batch), and 62 printed `Archive interrupted; ... the active transaction will roll back`. Eligible backlog: 3389 on 2026-10-23 → 4833 on 2026-11-02 → 6467 on 2026-11-14 → 6631 on 2026-11-16T03:00Z.
- `event`: 2,904,220 rows, 64.9 GB of payload (`SUM(octet_length(data))`). Of those, 1,333,893 rows (35.7 GB) belong to sessions in `ledger.worker_sessions` that have been inactive 60+ minutes, which is exactly the GH#38491 expiry filter. Yet every `Worker event expiry pass complete` line on this host reports `expired 0 ... 0 B freed`, including the shared-DB run at 2026-11-16T03:00Z.
- The 500-row expiry selection took 7.33 s cold and 0.01 s warm (host load 180-245 on 16 CPUs). The pass gets `max_duration/4` = 15 s, and `_archive_expire_worker_events` breaks on rc 124 without distinguishing "timed out" from "nothing to expire".
- `opencode-db-archive-async-helper.sh` runs the hourly `--worker-events-only` pass only after a full pass completed that day. Because the shared DB's full pass never completes, every hourly run is another full pass with the same 60 s outcome.

## What

`_archive_run_batches` in `.agents/scripts/opencode-db-archive.sh` shrinks `next_limit` only after a batch *succeeds* (about line 1581). Every run restarts at `ARCHIVE_BATCH_SIZE` (500, or 10 in held mode) and the 64 MiB `OPENCODE_DB_ARCHIVE_BATCH_BYTES`. `_archive_select_batch` (about line 1491) sizes each candidate with a separate `sqlite3` process using `LENGTH(CAST(data AS BLOB))`, which loads every payload, including overflow chains. When sizing plus copy + verify + delete (`_archive_execute_batch`, about line 1650) does not fit the remaining per-DB budget (`OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC`, 60 s, enforced by `_archive_with_deadline`), the deadline kills the batch, SQLite rolls it back, and the next run retries the identical batch. Worker-event expiry (`.agents/scripts/opencode-db-archive-worker-events.sh`) has the same failure mode with a fixed 500-row / 64 MiB batch.

Change:

1. **Persisted adaptation (both batch loops).** Keep a per-DB state file keyed by a hash of the active DB path, next to the existing `~/.aidevops/logs/opencode-db-archive.deferrals`, not beside the DB. Write an in-flight marker holding the current limits before each batch write. If a run starts and finds the marker, the previous batch never committed (deadline, SIGTERM or SIGKILL): halve the limits (floors: 1 session or 10 event rows; 1 MiB). After a committed batch, clear the marker and double the limits back toward the defaults. A worker-event batch that returns rc 124 halves its limits the same way.
2. **Cheap sizing.** Size the candidate prefix in one SQL query that uses `octet_length()` (SQLite 3.43+ reads only the record header; see `_archive_worker_event_size_expr`) with a cumulative window sum, instead of one `sqlite3` process per candidate. Keep the `LENGTH(CAST(... AS BLOB))` fallback for older SQLite.
3. **Order by value.** In `_archive_move_phase`, give worker-event expiry the larger share of the budget when the expirable set is non-empty. Events of terminated workers are expendable (GH#38491), and expiring them first means the session move no longer copies and verifies those bytes into the archive.
4. **Head-of-line protection.** If a 1-session batch is still interrupted, record that session ID as oversized-deferred and exclude it from `candidate_filter` on later runs. Log one warning naming the session and the remedy: a manual run with a larger `--max-duration-seconds` while the host is idle.
5. **Unambiguous logging.** Have the worker-event pass report `timed out after Ns; 0 committed` separately from `expired 0`. Add one per-DB line with per-phase seconds (event expiry, worker-event expiry, candidate preparation, sizing, each batch write).

Keep the idle gate, held-mode cap, copy → verify → delete semantics and per-DB deadline unchanged.

## Why

The archive is the only bound on the shared DB that every headless worker merges into (`_merge_worker_db` in `.agents/scripts/headless-runtime-database.sh`, 5 s busy timeout). Worker exit-86 shared-schema initialization failures also appear on this host; a causal link to DB size is not yet proven. A livelock that defers forever also misleads the deferral-streak notice, which blames holders, and 35.7 GB of reclaimable events stay in place.

## How (files)

- EDIT `.agents/scripts/opencode-db-archive.sh`: `_archive_run_batches` (about 1525-1588), `_archive_select_batch` (about 1491-1523), `_archive_execute_batch` (marker around the write, about 1650), `_archive_prepare_candidates` (oversized-deferred exclusion), `_archive_move_phase` (about 1202, budget split). Reference pattern for state files: `DEFERRALS_FILE` in `.agents/scripts/opencode-db-archive-async-helper.sh`.
- EDIT `.agents/scripts/opencode-db-archive-worker-events.sh`: `_archive_expire_worker_events` (rc 124 handling, persisted batch size, timeout log line).
- EDIT `.agents/scripts/tests/test-opencode-db-archive.sh` (existing archive and worker-event cases live here): add one case where a stubbed batch write exceeds the deadline once; assert that the next run halves the limit and archives at least one session.

### Files Scope

- `.agents/scripts/opencode-db-archive.sh`
- `.agents/scripts/opencode-db-archive-worker-events.sh`
- `.agents/scripts/tests/test-opencode-db-archive.sh`
- `TODO.md`

## Acceptance

- A run interrupted during a batch write leaves a marker, and the next run halves the session and byte limits before selecting.
- A committed batch clears the marker and grows the limits back toward the defaults.
- A worker-event batch that times out is logged as a timeout and halves its row/byte limits for the next run.
- Candidate sizing for one batch uses one SQLite query when `octet_length()` is available.
- A 1-session batch that is still interrupted is skipped on later runs, with one warning naming it.
- The existing archive and worker-event tests pass; ShellCheck is clean.
- After deployment, the shared-DB entries in `~/.aidevops/logs/opencode-db-archive.log` show non-zero `Worker event expiry pass complete: expired N` and `Archived N/M sessions` lines, and the eligible count falls across consecutive nightly runs.

## Verification

```bash
bash .agents/scripts/tests/test-opencode-db-archive.sh
shellcheck .agents/scripts/opencode-db-archive.sh .agents/scripts/opencode-db-archive-worker-events.sh
rg -n "Worker event expiry pass complete: expired [1-9]|Archived [0-9]+/[0-9]+ sessions" ~/.aidevops/logs/opencode-db-archive.log | tail -n 20
```
