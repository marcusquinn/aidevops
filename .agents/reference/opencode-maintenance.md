<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# OpenCode Database Maintenance

Periodic SQLite maintenance for opencode's session database to reduce
"database is locked" errors under concurrent session load.

## The problem

opencode stores session state in `~/.local/share/opencode/opencode.db`
(SQLite with WAL journaling). Under heavy use:

- **DB grows large**. Active users accumulate 1 GB+ of `message` and `part`
  rows (typical ratio: 65% message, 30% part, 5% indexes).
- **WAL single-writer limit**. SQLite WAL allows concurrent readers but only
  one writer at a time. Long write transactions (large tool outputs — see
  anomalyco/opencode#21000) block other writers.
- **busy_timeout caps retry time**. opencode applies `PRAGMA busy_timeout =
  5000ms`. When a writer exceeds 5 s, `SQLITE_BUSY` surfaces as the red
  "database is locked" banner and the session halts mid-turn.

The architectural fix is upstream — per-session-tree sharding (PR
anomalyco/opencode#21579) or a multi-writer backend. Until that lands,
keeping the DB compact and WAL truncated minimises write-lock hold time.

## What this routine does

`r913 Weekly opencode DB maintenance` runs every Sunday at 04:00 local
time and invokes `opencode-db-maintenance-helper.sh auto`, which:

1. **Guards**. Exits 0 silently if opencode isn't installed. Throttles
   if the last successful run was within 6 days. Refuses to run while
   opencode processes are active (requires exclusive DB access).
2. **wal_checkpoint(TRUNCATE)**. Folds pending WAL writes back into the
   main DB and truncates the WAL file to zero.
3. **PRAGMA optimize**. Refreshes query planner statistics so common
   session queries pick the right indexes.
4. **VACUUM** (conditional). Rewrites the DB file, reclaiming free pages
   from deleted rows. Runs when the DB is larger than 500 MB or free pages
   exceed 10% of total pages. Typical reclaim: 20–40% on DBs with heavy
   prune activity.
5. **Final WAL checkpoint**. VACUUM itself can write a DB-sized WAL. The helper
   runs a final `wal_checkpoint(TRUNCATE)` before declaring success.

## Subcommands

User-facing CLI entry point:

```bash
aidevops opencode-db check    # preflight: DB exists, no locks, integrity OK
aidevops opencode-db report   # stats (size, pages, free list, top tables)
aidevops opencode-db maintain # run once (refuses if processes active)
aidevops opencode-db maintenance-window --force-opencode
aidevops opencode-db status   # scheduler install state
```

The CLI delegates to the helper; direct helper calls remain supported for tests
and advanced scripting:

```bash
opencode-db-maintenance-helper.sh check    # preflight: DB exists, no locks, integrity OK
opencode-db-maintenance-helper.sh report   # stats (size, pages, free list, top tables)
opencode-db-maintenance-helper.sh maintain # run once (refuses if processes active)
opencode-db-maintenance-helper.sh maintain --force  # run anyway (may cause session errors)
opencode-db-maintenance-helper.sh maintenance-window --force-opencode
opencode-db-maintenance-helper.sh auto     # scheduled mode (silent, throttled)
opencode-db-maintenance-helper.sh notice   # one-line session-start toast notice
opencode-db-maintenance-helper.sh help
```

## Session-start notice

OpenCode session-start toasts include a one-line maintenance notice when either:

- maintenance is recommended (no previous run, DB/WAL above thresholds, or the
  last run is older than `AUTO_MIN_SECONDS_BETWEEN`), or
- `OPENCODE_DB_MAINTENANCE_MODE=maintenance-window` is configured.

The disruptive scheduled-mode notice includes the weekly day/time and explicitly
states that pulse/headless workers pause during the maintenance window.

### Sample output

```text
== OpenCode DB Report ==

  Path:          /Users/alice/.local/share/opencode/opencode.db
  DB size:       1.22 GB
  WAL size:      3.0 MB
  Pages:         320588 (page_size=4096B)
  Free pages:    29312 (9.14% of total)

  PRAGMAs (fresh CLI connection — not what opencode uses):
    journal_mode = wal
    synchronous  = 1
    busy_timeout = 0
    mmap_size    = 0

  Top 5 tables/indexes by size:
    message                                  793.3 MB
    part                                     561.2 MB
    part_message_id_id_idx                   12.0 MB
    part_session_idx                         6.7 MB
    sqlite_autoindex_part_1                  6.7 MB
```

The `busy_timeout = 0` shown is from a fresh `sqlite3` CLI connection, not
from opencode's internal connections. opencode applies `PRAGMA busy_timeout
= 5000` at connection open time; that setting is per-connection and does not
persist to the DB file. Useful when diagnosing edge cases where opencode
opens a new connection path that forgets to apply the standard pragmas.

## Configuration

All thresholds overrideable via environment variables:

| Variable | Default | Description |
|---|---|---|
| `VACUUM_FREELIST_THRESHOLD` | `0.10` | VACUUM if free-page fraction >= this |
| `FORCE_VACUUM_SIZE_MB` | `500` | Always VACUUM above this size (MB) |
| `AUTO_MIN_SECONDS_BETWEEN` | `518400` | Throttle for `auto` mode (6 days) |
| `WAL_LARGE_THRESHOLD_MB` | `500` | Report checkpoint/busy details above this WAL size |
| `MAINTENANCE_WINDOW_KEEP_SESSIONS` | `500` | Count target used by `maintenance-window` archive |
| `OPENCODE_DB_MAINTENANCE_HOUR` | `4` | Scheduled local hour for the weekly routine |
| `OPENCODE_DB_MAINTENANCE_MINUTE` | `0` | Scheduled local minute for the weekly routine |
| `OPENCODE_DB_MAINTENANCE_MODE` | `auto` | `auto` or disruptive `maintenance-window` scheduler mode |

Example: force VACUUM on every run regardless of fragmentation:

```bash
FORCE_VACUUM_SIZE_MB=0 VACUUM_FREELIST_THRESHOLD=0.0 \
  opencode-db-maintenance-helper.sh maintain
```

## Archive retention modes

`opencode-db-archive.sh archive` supports two retention targets:

- **Age-based retention** (`--retention-days N`) archives sessions older than
  `N` days. This remains the default mode (`14` days) and is best when session
  volume is predictable.
- **Count-based retention** (`--keep-sessions N`) keeps the newest `N` active
  sessions and archives older sessions beyond that budget. Use this when TUI
  startup cost tracks active session count more closely than calendar age, for
  example keeping roughly the newest 500 sessions active.

Examples:

```bash
# Keep roughly the newest 500 active sessions, archive older sessions
opencode-db-archive.sh archive --keep-sessions 500

# Preview a stricter active-session budget first
opencode-db-archive.sh archive --keep-sessions 250 --dry-run

# Conservative combined mode: archive only sessions older than 30 days AND
# outside the newest 500 sessions
opencode-db-archive.sh archive --retention-days 30 --keep-sessions 500
```

When both modes are provided, the archive uses the conservative intersection:
recent sessions are preserved if they are within either the age window or the
newest-session budget.

## Disruptive maintenance window

`opencode-db-maintenance-helper.sh maintenance-window` is for explicit off-hours
windows where the operator accepts interruption risk to get a compact DB and a
truncated WAL.

It does this in order:

1. Stops aidevops-managed pulse/headless workers with `pulse-lifecycle-helper.sh
   stop`.
2. Archives old sessions with `opencode-db-archive.sh archive --keep-sessions
   ${MAINTENANCE_WINDOW_KEEP_SESSIONS}`.
3. Runs normal maintenance, including final post-VACUUM WAL checkpoint.
4. Runs `PRAGMA quick_check`.
5. Restarts pulse in a trap/finally path with `pulse-lifecycle-helper.sh start`.

Interactive OpenCode TUIs are not killed automatically. If any TUI still holds
the DB, the command exits with guidance unless `--force-opencode` is passed. Use
that flag only when the remaining holder is the session coordinating the window.

To schedule the disruptive mode instead of the safe no-op mode:

```bash
OPENCODE_DB_MAINTENANCE_MODE=maintenance-window \
OPENCODE_DB_MAINTENANCE_HOUR=8 \
  aidevops opencode-db install
```

## Safety

- **Never runs with active opencode processes** in `auto` or plain
  `maintain` mode. A running opencode TUI holds WAL locks; VACUUM
  requires exclusive access. The check uses `pgrep` for `opencode-ai/bin/.opencode`.
- **Disruptive mode is explicit**. `maintenance-window` may stop pulse/headless
  workers and requires `--force-opencode` before it continues with an
  interactive TUI holding the DB.
- **No data loss from VACUUM**. SQLite VACUUM rewrites the DB file
  page by page, preserving every row. If interrupted, SQLite's journal
  restores the previous state.
- **Throttled**. `auto` mode skips if `last-run.json` shows success
  within the last 6 days. Manual `maintain` is not throttled.

## State

- `~/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json`
  — last run outcome, timestamps, reclaimed bytes, VACUUM decision
- `~/.aidevops/.agent-workspace/work/opencode-maintenance/maintenance.log`
  — append-only history

## Project ID drift — /sessions loses history

**Symptom:** The TUI `/sessions` picker shows only the current session (or a handful of recent ones), not the full history. Closing and reopening opencode does not help.

**Cause:** Opencode identifies git-tracked projects by a **git commit SHA** stored in `session.project_id`. The `/sessions` picker filters by the *current* session's `project_id`. When opencode regenerates this SHA (binary update, rebase, or certain git reference events), prior sessions orphan onto the old `project_id` and disappear from the picker. They are NOT deleted.

**Diagnose:** Close opencode TUI first, then inspect the DB:

```bash
# List project_ids seen for a given repo directory, ordered by session count
sqlite3 ~/.local/share/opencode/opencode.db \
  "SELECT project_id, COUNT(*) FROM session
    WHERE directory='/absolute/path/to/repo'
    GROUP BY project_id ORDER BY 2 DESC;"
```

If two or more project_ids appear, the one with the highest count is the orphaned history; the one the TUI currently uses is whichever matches a new session (usually lower count).

**Fix:** Remap orphaned sessions to the current project_id. Close the opencode TUI first to avoid WAL lock contention:

```bash
# Replace OLD_SHA and NEW_SHA with the actual values from the diagnose step
sqlite3 ~/.local/share/opencode/opencode.db \
  "UPDATE session SET project_id='NEW_SHA' WHERE project_id='OLD_SHA';"
```

Reopen the TUI — `/sessions` now shows the full history.

**Archive DB:** `opencode-archive.db` is not read by the TUI regardless of `project_id`. No remap is needed there unless you are restoring archived sessions (in which case apply the same remap to the archive DB before running `opencode-db-archive.sh restore`).

## Related upstream issues

- [anomalyco/opencode#21215](https://github.com/anomalyco/opencode/issues/21215) — concurrent sessions crash with SQLITE_BUSY
- [anomalyco/opencode#21000](https://github.com/anomalyco/opencode/issues/21000) — Bash tool hangs and locks database on massive output
- [anomalyco/opencode#20935](https://github.com/anomalyco/opencode/issues/20935) — per-session-tree database sharding (architectural fix, open)
- [anomalyco/opencode#21579](https://github.com/anomalyco/opencode/pull/21579) — harden per-session SQLite sharding (PR, open)
- [anomalyco/opencode#19521](https://github.com/anomalyco/opencode/issues/19521) — database is locked (original report)

## What aidevops cannot fix from outside opencode

These require opencode source changes (tracked upstream):

- Raising `busy_timeout` 5000 ms → 30000 ms (per-connection, set at open)
- Enabling `mmap_size` (per-connection — reduces read contention)
- Retry-with-exponential-backoff on `SQLITE_BUSY` in the write path
- Switching long `BEGIN IMMEDIATE` to `BEGIN DEFERRED` for read paths
- Session-tree DB sharding (PR #21579)

Periodic VACUUM + checkpoint is the only mitigation applicable from
outside opencode's process.
