<!-- aidevops:brief-schema=v2 -->

# t19016: perf(profile): project OpenCode usage rows per table instead of materializing the full message history

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (aidevops productivity mission, parent t19002 / GH#38332)
- **Conversation context:** Host contention diagnosis on the 20-slot macOS Pulse runner. Load average was 87 on 16 cores while Pulse census scans and dispatch pre-launch checks were running slowly.

## What

`_get_model_usage_from_opencode` in `.agents/scripts/profile-readme-data-lib.sh` should compute the all-time model-usage table from small projected rows. It must not copy every message's raw JSON into a SQLite temp B-tree. The output must stay byte-for-byte identical.

## Why

The query builds `all_messages AS (SELECT session_id, data FROM message UNION ALL SELECT session_id, data FROM archive.message)`. Later CTEs reference it twice, through the main `GROUP BY` and the `total_session_count` scalar subquery, so SQLite materializes it (`EXPLAIN QUERY PLAN`: `MATERIALIZE all_messages`). On this install that copies about 9.2 GB of message JSON (2.19 GB main and 6.99 GB archive, 1.1M rows) to temp storage before any aggregation. The hourly `sh.aidevops.profile-readme-update` launchd job runs at Nice 10 with `LowPriorityBackgroundIO`, so that copy took hours:

| Evidence | Value |
| --- | --- |
| r908 executions.jsonl durations | 8,320 s, 18,561 s; the 2026-11-14T20:24Z run was still running at 7 h 19 m |
| Runs back-to-back (StartInterval 3600) | continuous for at least 4 days (`profile-readme-update.log` start times) |
| The one sqlite3 query still running at diagnosis | 62 min |
| Same aggregation, projected per table (measured on the real DBs) | 15 s, 55 models, 1,044,716 requests |
| Observability-DB queries in the same run | 3 s and 1 s; not a cause |

The hourly job is a background statistics task. It held sustained temp-file I/O on the same host that runs Pulse, its workers and the interactive sessions.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** One SQL restructure in one shell library. The output contract is unchanged and was verified for equality on a sampled fixture.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/profile-readme-data-lib.sh` — add `_opencode_assistant_rows_sql <table>`, which emits the existing projection and filter for one table. `_get_model_usage_from_opencode` builds `assistant_messages_raw` as the main projection, `UNION ALL` the archive projection when the archive exists. The later CTEs and the final aggregate stay unchanged. Only the small projected rows can be materialized.

### Verification

```bash
shellcheck -x -P .agents/scripts .agents/scripts/profile-readme-data-lib.sh
bash .agents/scripts/tests/test-profile-readme-boundary.sh
# Equivalence: deployed and patched functions return identical JSON on a
# fixture of 40k main + 40k archive messages copied from the real DBs, with
# the archive present and absent.
# Runtime, after deploy: r908 durations in
# ~/.aidevops/.agent-workspace/cron/r908/logs/executions.jsonl drop from
# hours to minutes.
```

### Files Scope

- `.agents/scripts/profile-readme-data-lib.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] `EXPLAIN QUERY PLAN` for the OpenCode usage query never materializes raw `data` columns.
- [ ] Output is identical to the previous query with and without the archive DB.
- [ ] The existing profile README boundary test passes.
- [ ] Runtime: the next r908 runs after deploy complete in minutes, not hours.

## Context & Decisions

- A TTL cache for all-time totals was rejected. It would still need a multi-hour scan once a day, and the defect is the query shape, not the cadence.
- `_token_totals_from_opencode_db` already projects inside each `UNION ALL` branch, and the observability queries are flattened by SQLite (measured at 1–3 s), so they are unchanged.
