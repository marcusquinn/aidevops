<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# OpenCode Active-DB Event Retention (GH#38630)

Part of `reference/opencode-maintenance.md`. OpenCode re-serialises payloads
(including the full `summary.diffs`) into every `message.updated` /
`message.part.updated` event, so the `event` table once held ~64 GB of a 72 GB DB
(GH#38491, GH#35222, GH#38630). The transcript lives in `session`/`message`/`part`;
events are expendable.

`opencode-db-archive.sh archive --worker-events-only` (run first by every
`opencode-db-archive-async-helper.sh` invocation, before the full pass) deletes
`event` rows of **any** session (interactive, worker, subagent) whose
`time_updated` is older than `OPENCODE_DB_ARCHIVE_EVENT_IDLE_MINUTES` (default 60;
legacy `OPENCODE_DB_ARCHIVE_WORKER_EVENT_MINUTES` and
`--worker-event-expiry-minutes` still work; 0 disables). It keeps sessions inside
the window, running workers named in pulse logs, `session`/`message`/`part`/`todo`
and `event_sequence`.

- Short batched write transactions (`OPENCODE_DB_ARCHIVE_WORKER_EVENT_BATCH_SIZE` /
  `_BATCH_BYTES`, adaptive), least recently updated sessions first. It never waits
  for idle holders and does not depend on the full pass; `SQLITE_BUSY` after a 5 s
  timeout defers (rc 2) to the next hourly run. `--dry-run` reports rows and bytes.
- `OPENCODE_DB_EVENT_MAX_BYTES` (default 2 GiB of payload) is the ceiling: the pass
  warns above it, `opencode-db-maintenance-helper.sh report` prints event
  rows/bytes, and `notice` warns above it or when the DB grew over 5 GB since the
  previous report. Sessions inside the idle window are never expired, so an active
  session can exceed the cap until it goes idle.
- The full archive move no longer pre-expires events; sessions it moves carry
  their events.
