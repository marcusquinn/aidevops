<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# OpenCode Database Maintenance

Periodic SQLite maintenance for opencode's session database to reduce
"database is locked" errors under concurrent session load.

## The problem

opencode stores session state in `~/.local/share/opencode/opencode.db`
(SQLite with WAL journaling). Under heavy use:

- **DB grows large**. Active users routinely accumulate 1 GB+ of message
  and part rows. `message` and `part` dominate the schema (typical ratio:
  65% message, 30% part, 5% indexes).
- **Multiple connections per process**. Each opencode binary opens at
  least 2 DB connections — one for reads, one for writes. A single TUI
  with 10+ FDs on the DB is already multi-writer from SQLite's perspective.
- **WAL single-writer limit**. SQLite WAL allows concurrent readers but
  only *one* writer at a time. When a write transaction runs long
  (large tool outputs are a common trigger — see anomalyco/opencode
  #21000), other writers block.
- **busy_timeout caps retry time**. opencode applies `PRAGMA busy_timeout
  = 5000ms` on its connections. When a writer exceeds 5 seconds, retries
  exhaust and SQLite returns `SQLITE_BUSY`, surfacing as the red "database
  is locked" banner. The session halts mid-turn.

The architectural fix is upstream — per-session-tree sharding (PR
anomalyco/opencode#21579) or switching to a multi-writer backend. Until
that lands, the best mitigation is to keep the DB compact and the WAL
truncated so write transactions hold the lock for as short a time as
possible.

## What this routine does

`r913 Weekly opencode DB maintenance` runs every Sunday at 04:00 local
time and invokes `opencode-db-maintenance-helper.sh auto`, which:

1. **Guards**. Exits 0 silently if opencode isn't installed. Throttles
   if the last successful run was within 6 days. Refuses to run while
   opencode processes are active (requires exclusive DB access).
2. **wal_checkpoint(TRUNCATE)**. Folds pending WAL writes back into the
   main DB and truncates the WAL file to zero. Prevents WAL bloat during
   the following week's burst writes.
3. **PRAGMA optimize**. Refreshes query planner statistics so common
   session queries pick the right indexes.
4. **VACUUM** (conditional). Rewrites the DB file, reclaiming free pages
   from deleted rows (opencode prunes old sessions in the background).
   Runs when the DB is larger than 500 MB or free pages exceed 10% of
   total pages. Typical reclaim: 20–40% on DBs with heavy prune activity.

## Subcommands

```bash
opencode-db-maintenance-helper.sh check    # preflight: DB exists, no locks, integrity OK
opencode-db-maintenance-helper.sh report   # stats (size, pages, free list, top tables)
opencode-db-maintenance-helper.sh maintain # run once (refuses if processes active)
opencode-db-maintenance-helper.sh maintain --force  # run anyway (may cause session errors)
opencode-db-maintenance-helper.sh auto     # scheduled mode (silent, throttled)
opencode-db-maintenance-helper.sh help
```

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

### Why the PRAGMA section says `busy_timeout = 0`

The PRAGMAs displayed are from a *fresh* `sqlite3` CLI connection, not
from opencode's internal connections. opencode applies
`PRAGMA busy_timeout = 5000` at connection open time, but that setting
is per-connection and does not persist to the DB file. The report
surfaces the SQLite defaults so you can see what the DB file itself
knows about — useful when diagnosing edge cases where opencode opens
a new connection path that forgets to apply the standard pragmas.

## Configuration

All thresholds overrideable via environment variables:

| Variable | Default | Description |
|---|---|---|
| `VACUUM_FREELIST_THRESHOLD` | `0.10` | VACUUM if free-page fraction >= this |
| `FORCE_VACUUM_SIZE_MB` | `500` | Always VACUUM above this size (MB) |
| `AUTO_MIN_SECONDS_BETWEEN` | `518400` | Throttle for `auto` mode (6 days) |

Example: force VACUUM on every run regardless of fragmentation:

```bash
FORCE_VACUUM_SIZE_MB=0 VACUUM_FREELIST_THRESHOLD=0.0 \
  opencode-db-maintenance-helper.sh maintain
```

## Safety

- **Never runs with active opencode processes** in `auto` or plain
  `maintain` mode. A running opencode TUI holds WAL locks; VACUUM
  requires exclusive access and would fail or (worse) conflict. The
  check uses `pgrep` for `opencode-ai/bin/.opencode`.
- **No data loss from VACUUM**. SQLite VACUUM rewrites the DB file
  page by page, preserving every row. If interrupted, SQLite's
  journal restores the previous state.
- **Throttled**. `auto` mode skips if `last-run.json` shows success
  within the last 6 days. Manual `maintain` is not throttled.

## State

- `~/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json`
  — last run outcome, timestamps, reclaimed bytes, VACUUM decision
- `~/.aidevops/.agent-workspace/work/opencode-maintenance/maintenance.log`
  — append-only history

## Related upstream issues

- [anomalyco/opencode#21215](https://github.com/anomalyco/opencode/issues/21215)
  — opencode run: concurrent sessions crash with SQLITE_BUSY
- [anomalyco/opencode#21000](https://github.com/anomalyco/opencode/issues/21000)
  — Bash tool hangs on fast-exiting processes and locks database on massive output
- [anomalyco/opencode#20935](https://github.com/anomalyco/opencode/issues/20935)
  — Per-session-tree database sharding (architectural fix, open)
- [anomalyco/opencode#21579](https://github.com/anomalyco/opencode/pull/21579)
  — Harden per-session SQLite sharding (PR, open)
- [anomalyco/opencode#19521](https://github.com/anomalyco/opencode/issues/19521)
  — database is locked (original report)

## What aidevops cannot fix from outside opencode

These require opencode source changes (tracked upstream):

- Raising `busy_timeout` from 5000ms → 30000ms (per-connection, must
  be set by opencode at connection open)
- Enabling `mmap_size` (per-connection — would significantly reduce
  read contention by memory-mapping the DB file)
- Retry-with-exponential-backoff on `SQLITE_BUSY` in the write path
  (write wrapper change in opencode's session.processor service)
- Switching long `BEGIN IMMEDIATE` transactions to `BEGIN DEFERRED`
  for read paths (transaction-mode choice in application code)
- Session-tree DB sharding (PR #21579)

Periodic VACUUM + checkpoint is the only mitigation applicable from
outside opencode's process.
