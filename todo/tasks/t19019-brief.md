<!-- aidevops:brief-schema=v2 -->

# t19019: perf(opencode-db): restore archived interactive sessions on resume so the live DB can keep 30 days instead of 90

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (aidevops productivity mission, parent t19002 / GH#38332)
- **Conversation context:** Host contention diagnosis on the 20-slot Pulse runner (load ~87 on 16 cores). Every full-file consumer of the live OpenCode DB scales with its size.

## What

1. Resuming an archived interactive session (`opencode --session ses_...` or the aidevops resume or lookup path) restores it from `opencode-archive.db` first, as headless workers already do (`_seed_worker_db_session_context` → `opencode-db-archive.sh restore --session <id>`).
2. Once (1) ships, the default interactive live retention (`OPENCODE_DB_ARCHIVE_INTERACTIVE_RETENTION_DAYS`, currently 90) drops to 30.

## Why

Measured on this host on 2026-11-15:

| Fact | Value |
| --- | --- |
| Live `~/.local/share/opencode/opencode.db` | 62.2 GB, `freelist_count=0` (all live pages) |
| Sessions in live DB / older than 30 d / oldest | 7,253 / 3,250 / 2026-09-23 (53 days) |
| Approximate growth | about 1.2 GB per day, so about 105 GB at the 90-day steady state |
| `message` table share | about 2.2 GB; the rest is mostly `part` (tool output) |

Every full-file consumer of the live DB scales with that size:

- Time Machine includes the file and copies changed files whole. It completes a backup every 4–5 h here.
- Backblaze queued it hourly for a "large file requires disk copy".
- Whole-history readers (profile README, session-time) scan it.
- VACUUM needs a DB-sized rewrite, which is unreachable on always-on hosts (`reference/opencode-maintenance.md`).

Interactive retention is 90 days because archived interactive sessions cannot be resumed without a manual `restore`.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The resume hook location must be found, and must cover the TUI launch paths without breaking non-aidevops OpenCode use.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/opencode-session-restart-helper.sh` (interactive resume path) — restore before OpenCode opens the session; a missing archive is a no-op. Other interactive launch paths, such as the opencode-aidevops plugin session start, are unknown: find them with `rg -n 'restore --session|_seed_worker_db_session_context|--session' .agents/scripts .agents/plugins`. Reuse `.agents/scripts/opencode-db-archive-restore.sh`.
- `EDIT: .agents/scripts/opencode-db-archive.sh` — `DEFAULT_INTERACTIVE_RETENTION_DAYS` from 90 to 30, only after the resume restore is verified.
- `EDIT: .agents/reference/opencode-maintenance.md` — retention table and the resume behaviour.

### Verification

```bash
bash .agents/scripts/tests/test-opencode-db-archive.sh
# Product path: archive an idle interactive session, resume it through the
# normal resume command, confirm its transcript is present and the session
# row is back in the live DB.
```

### Files Scope

- `.agents/scripts/opencode-db-archive.sh`
- `.agents/scripts/opencode-db-archive-restore.sh`
- `.agents/scripts/opencode-session-restart-helper.sh`
- `.agents/reference/opencode-maintenance.md`

## Acceptance Criteria

- [ ] Resuming an archived interactive session through the aidevops resume path restores it with subagent children and opens normally.
- [ ] The default interactive retention is 30 days, and the env override still works.
- [ ] The existing archive tests pass.

## Context & Decisions

- Halting growth is the first outcome: archived rows free pages that later writes reuse. Shrinking the file still needs a maintenance-window VACUUM. Do not force one here.
- Rejected: excluding the live DB from backups. Session history is valuable, and a backup exclusion trades data safety for I/O.
