## What

Make the profile README `session-time --period profile` collection bounded and incremental, so the hourly profile routine finishes in minutes under launchd Background priority. Today it does not.

## Why

Observed on 2026-11-27 on the maintainer host (aidevops v3.39.290/291, macOS, `llm-requests.db` about 17 GB plus OpenCode session DBs and monthly archives):

- The 19:00Z profile routine was still inside `contributor-activity-helper.sh session-time --all-dirs --period profile --format json` after 70 minutes.
- Its Python child, `session-time-interval-engine.py --period profile --all-dirs`, had used 42 s of CPU in those 70 minutes, at 0% CPU and state `RN`. It is I/O-bound under the routine's `ProcessType Background` / `LowPriorityBackgroundIO` throttle.
- A second diagnostic run of the same step was still running after 29 minutes and was cancelled.
- The previous run (17:06Z to 17:54Z) took 48 minutes. Overlapping hourly runs log `Profile README update already running; skipping overlapping refresh`, so the README refreshes only every 1–2 hours.
- This is the same mechanism fixed for AI Model Usage in t19429 / GH#40606 (PR #40610, v3.39.291): a full year-window re-scan of large SQLite sources on every run, starved by Background I/O. That fix moved model usage to an incremental rowid-watermark rollup (`.agents/scripts/profile-readme-usage-rollup-lib.sh`). Session time still re-reads everything:
  - `SESSION_QUERY` in `.agents/scripts/session_time_db.py:28` joins `session` and `message` for every root DB and archive segment since `now - 1 year`, evaluating `json_valid` and `json_extract` per row.
  - `OBS_QUERY` (`session_time_db.py:34`) scans `llm_requests` over the same window.
- No timeout bounds the step (`_get_profile_session_times` in `.agents/scripts/profile-readme-data-lib.sh:294`). Its fallback is an all-`unavailable` payload only on error, not on slowness.

## How

### Files to Modify

- `EDIT: .agents/scripts/session_time_db.py` / `.agents/scripts/session-time-interval-engine.py`: add an incremental derived store, or reuse the existing `--cache-file` path, so each run reads only rows newer than a persisted watermark per source DB. Per-session interval state must stay correct across the watermark. Immutable monthly archive segments (`archive_segments`, GH#40419) can be summarised once and keyed by file identity (size + mtime).
- `EDIT: .agents/scripts/profile-readme-data-lib.sh:294` `_get_profile_session_times`: bound the step with `timeout_sec`, as `_profile_sqlite_read` does at line 370. On timeout, report an explicit incomplete status and keep the previously published "Work with AI" sections, following `_render_preserved_model_usage_sections` in `.agents/scripts/profile-readme-render-lib.sh`. Never publish zeros or unavailable values as fresh data.
- Reference pattern: `.agents/scripts/profile-readme-usage-rollup-lib.sh`. It uses a rowid watermark, chunked short read-only transactions, a time budget, resumable bootstrap and a rebuild when the source shrinks.

### Files Scope

- `.agents/scripts/session_time_db.py`
- `.agents/scripts/session_time_db_roots.py`
- `.agents/scripts/session-time-interval-engine.py`
- `.agents/scripts/session_time_aggregate.py`
- `.agents/scripts/profile-readme-data-lib.sh`
- `.agents/scripts/profile-readme-render-lib.sh`
- `.agents/scripts/tests/test-profile-readme-boundary.sh`

## Acceptance

- On a host with a multi-GB OpenCode DB and `llm-requests.db`, a steady-state `contributor-activity-helper.sh session-time --all-dirs --period profile --format json` completes in under 60 s at Background priority (`taskpolicy -b`). The first build may resume across runs.
- Parity: incremental output equals the current full-scan output for `day`, `week`, `28d` and `year` on the same snapshot (record the command and diff in the PR).
- A timed-out or incomplete session-time step keeps the previously published sections instead of rendering them as unavailable or zero.
- `bash .agents/scripts/tests/test-profile-readme-boundary.sh` passes; ShellCheck and the Python lint used by CI are clean.
