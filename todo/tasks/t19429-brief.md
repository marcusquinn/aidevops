## What

Make the profile README "AI Model Usage" tables correct again and keep them correct: serve them from an incremental rollup of `llm-requests.db`, and never publish a different-population fallback when the observability source exists but could not be read.

## Why

Observed on 2026-11-27 on the maintainer profile README:

- "AI Model Usage (last 30 days)" showed one row: `claude-haiku-5-5 | 12 requests | 0 tokens`. The live observability DB holds 661,977 requests in that window (claude-opus-5-5 alone has 380,182).
- "AI Model Usage (all time)" showed claude-opus-5-5 at 39,306 requests. The observability DB holds 653,478 (2,302,386 requests in total).
- `~/.aidevops/.agent-workspace/logs/profile-readme-update.log` shows `[profile-readme] WARN: SQLite read of llm-requests.db exceeded 300s; using the next stats source` on many hourly runs since t19374 (`9529ce0e47`).

Root cause:

1. t19374 bounded every profile SQLite read to 300 s. The hourly routine runs as launchd `ProcessType Background` + `Nice 10` + `LowPriorityBackgroundIO`. Each run re-aggregates the whole 17.9 GB `llm-requests.db` twice (30-day and all-time). That takes 49 s and 58 s at normal priority, but regularly takes more than 300 s under Background I/O throttling.
2. On a timeout, `_get_model_usage_from_obs_db` returns empty. The callers then fall back to a different population and publish it as if it were current. The 30-day table falls back to the legacy `metrics.jsonl` (12 Haiku rows with no token fields). The all-time table falls back to the OpenCode message DB, which archives and expires history.

## How

### Files to Modify

- `NEW: .agents/scripts/profile-readme-usage-rollup-lib.sh` — incremental rollup of `llm-requests.db`

### Files Scope

- `.agents/scripts/profile-readme-usage-rollup-lib.sh`
- `.agents/scripts/profile-readme-data-lib.sh`
- `.agents/scripts/profile-readme-render-lib.sh`
- `.agents/scripts/profile-readme-helper.sh`
- `.agents/scripts/tests/test-profile-readme-boundary.sh`

### Changes

1. A new rollup library maintains `profile-usage-rollup.db` next to `llm-requests.db`. It is a derived per-(UTC hour, model, session) aggregate. The library attaches the source with `?mode=ro`, reads only rows above a rowid watermark, and works in short chunks with their own transactions. It stays under a time budget and persists progress between runs, and it rebuilds itself when the source shrinks below the watermark.
2. `_get_model_usage_from_obs_db` serves the 30-day and all-time aggregates from the rollup. It returns status 3 when the source exists but the rollup is not complete (first bootstrap, timeout, or error).
3. On status 3, the bundle reports `incomplete`. The renderer then keeps the previously published model-usage sections, with no JSONL or OpenCode substitution. The legacy fallbacks remain only for installs that have no observability DB.

## Acceptance

- On the live DB, the rollup results match the direct `llm_requests` aggregates. Allowed differences are rows written between runs and the 30-day boundary, which the rollup rounds to the UTC hour.
- Steady-state hourly runs read only new rows, which takes seconds and no longer depends on the 17.9 GB scan.
- A forced bootstrap timeout keeps the previous README sections and never renders JSONL or OpenCode substitutes.
- ShellCheck is clean, and `.agents/scripts/tests/test-profile-readme-boundary.sh` passes.
