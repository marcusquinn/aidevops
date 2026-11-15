<!-- aidevops:brief-schema=v2 -->

# t19024: perf(session-time): project message role and completion time in SQL instead of sorting raw message JSON

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (aidevops productivity mission, parent GH#38332)
- **Conversation context:** Follow-up to t19016 (PR #38427). That PR fixed the model-usage query in the hourly profile README job. The job is still slow because the session-time step has the same defect.

## What

The session-time engine in `.agents/scripts/session_time_db.py` and `.agents/scripts/session_time_db_roots.py` should select only the message fields it uses: JSON validity/type, `role` and `time.completed`. The aggregation output must stay the same.

## Why

`SESSION_QUERY` selects `m.data`, the full message JSON, and orders by `s.id, m.time_created`. `EXPLAIN QUERY PLAN` reports `USE TEMP B-TREE FOR ORDER BY`, so SQLite copies every raw message blob in the window into a temp file before Python sees a row. OpenCode user messages can include large diff summaries. Some rows are over 60 MB, and recent rows average about 83 KB.

| Evidence | Value |
| --- | --- |
| `session-time-interval-engine.py --period profile --all-dirs` still running at diagnosis | 3 h 50 m, state R, under the 05:05 local `sh.aidevops.profile-readme-update` run |
| SQLite temp sort file held by that process (`etilqs_*`) | 1.67 GB and growing |
| Last r908 execution (`executions.jsonl`) | 27,671 s, status failure |
| Live OpenCode WAL held open by that reader | 2.2 GB (a long read snapshot stops checkpoints from resetting the WAL; all OpenCode sessions and workers on the host share it) |
| Projected query, same join, filter and order, main DB, 366 days | 174,351 rows in 11.2 s |
| Projected query, 7 days | 12,233 rows in 3.2 s |

The job runs hourly on the Pulse/worker host. A multi-hour reader on the shared OpenCode database adds temp I/O and keeps the WAL growing.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** One query projection in two Python modules. The record shape changes in one consumer. The output contract is unchanged.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/session_time_db.py` — add one shared projection used by `SESSION_QUERY`: `json_type(m.data)`, `json_type(m.data, '$.time')` and `json_extract(m.data, '$.role', '$.time.completed')`, each wrapped in `CASE WHEN json_valid(m.data)`. `consume_session_record` builds `(role, completed)` from the projected columns with the same rules as `parse_message`: the root must be an object, `time` must be absent or an object, and boolean `completed` maps to `None` through `safe_int`.
- `EDIT: .agents/scripts/session_time_db_roots.py` — use the same projection in `session_query` for root-filtered queries.

### Verification

```bash
python3 -m py_compile .agents/scripts/session_time_db.py .agents/scripts/session_time_db_roots.py
bash .agents/scripts/tests/test-contributor-session-archive.sh
# Equivalence: the deployed and patched engines return identical JSON for
# --period profile on a fixture DB with valid, invalid, non-object, null-time,
# boolean-completed and string-completed messages.
# Runtime, after deploy: r908 executions finish in minutes; no etilqs temp
# file grows under session-time-interval-engine.py.
```

### Files Scope

- `.agents/scripts/session_time_db.py`
- `.agents/scripts/session_time_db_roots.py`
- `TODO.md`

## Acceptance Criteria

- [ ] The session query never selects the raw `data` column.
- [ ] Engine JSON output is identical to the previous implementation on an edge-case fixture.
- [ ] `test-contributor-session-archive.sh` passes.
- [ ] Runtime: a full `profile-readme-helper.sh update` completes in minutes on this host.

## Context & Decisions

- Kept `ORDER BY s.id, m.time_created`. With small projected rows the temp sort is small, and the per-session role sequence stays the same.
- Multi-path `json_extract` returns one JSON array, so Python keeps JSON typing. A JSON `true` stays a boolean and is still rejected by `safe_int`.
- SQLite's `json_valid` is strict RFC 8259. Python's `json.loads` also accepts `NaN` and `Infinity`. A message containing those literals is now counted as skipped. OpenCode does not write them.
