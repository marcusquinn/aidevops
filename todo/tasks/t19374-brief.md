## What

Bound every SQLite read made by the hourly profile README routine, so one run can never hold a read transaction on `llm-requests.db` (or the OpenCode DBs) for hours.

## Why

Observed on a busy macOS runner on 2026-11-25:

- `sh.aidevops.profile-readme-update` (r908, hourly, launchd `ProcessType Background`, `Nice 10`) had been running for 14h22m. Its `sqlite3` child had been running `_get_model_usage_from_obs_db` against `~/.aidevops/.agent-workspace/observability/llm-requests.db` for 7h06m and had used 16 s of CPU, on a host with 0% idle CPU.
- That read transaction pinned the WAL: `llm-requests.db-wal` grew to 11.3 GB because no checkpoint could pass the reader's snapshot. After the stuck routine was terminated, the WAL checkpointed back to 0.7 MB.
- At normal priority the same queries are cheap. On the live 17.5 GB DB (2.23M rows), the all-time and 30-day aggregates each finish in 2–4 s warm, and a cold sequential scan takes about 16 s. The 7-hour runtime came from Background I/O throttling under host contention, not from query cost.
- The original brief suspected that the `filtered_requests` CTE was being materialized because it is referenced twice. `EXPLAIN QUERY PLAN` on SQLite 3.51 disproves this: it shows no `MATERIALIZE` step, and `SELECT *` and a narrow projection produce identical plans. No query rewrite is needed.
- `profile-readme-helper.sh` never sourced `shared-constants.sh`, even though `profile-readme-data-lib.sh` lists it as a dependency "via orchestrator". So `timeout_sec` was unavailable to the routine.

## How

### Files Scope

- `.agents/scripts/profile-readme-data-lib.sh`
- `.agents/scripts/profile-readme-helper.sh`

### Changes

1. `profile-readme-helper.sh`: source `shared-constants.sh` first. No variable or function names collide with the profile libraries.
2. `profile-readme-data-lib.sh`: add `_profile_sqlite_read <db> <sql>`. It runs `sqlite3 -readonly -cmd '.timeout 5000'` under `timeout_sec "${PROFILE_README_SQLITE_TIMEOUT_S:-300}"` and logs one stderr warning on timeout. It keeps the existing fail-soft contract: the caller gets empty output and falls back to its next source, which is the same path a locked or unreadable DB takes today.
3. Route all four SQLite reads through it: `_get_model_usage_from_opencode`, `_get_model_usage_from_obs_db`, `_token_totals_from_opencode_db`, and `_token_totals_from_obs_db`.

## Acceptance

- Old and new `_get_model_usage_from_obs_db` return the same model set and aggregates on the live DB for both the all-time and 30-day calls. The only allowed differences are rows written between runs.
- With `PROFILE_README_SQLITE_TIMEOUT_S=1`, the all-time call returns empty output within the bound and logs the warning instead of hanging.
- ShellCheck is clean, and `.agents/scripts/tests/test-profile-readme-boundary.sh` passes.
