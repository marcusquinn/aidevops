<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2867: P2b — inbox capture CLI + watch folder + audit log

## Pre-flight

- [x] Memory recall: "fswatch watch folder helper" — no direct hits; adapt from cron-style routine pattern
- [x] Discovery pass: no in-flight PRs touching `_inbox/` capture surface
- [x] File refs verified: pattern source `worktree-helper.sh` for subcommand structure
- [x] Tier: `tier:standard` — CLI surface + filesystem watcher

## Origin

- **Created:** 2026-04-25
- **Session:** Claude Code interactive session (t2840 P2 phase)
- **Created by:** ai-interactive
- **Parent task:** t2840 / GH#20892
- **Conversation context:** Capture path for `_inbox/`. Friction-free drop is the value prop — multiple capture surfaces feed the same audit log.

## What

Implements the user-facing capture surface. Users can drop files via CLI (`aidevops inbox add <file|url>`) or by dragging into the watched `_inbox/_drop/` folder. Each capture appends a JSONL line to `_inbox/triage.log` recording timestamp, source method, original location, current location, and pending status (awaiting triage).

Watch folder uses `fswatch` if available, falls back to a polling-only routine for installations without fswatch. Detection of new files in `_drop/` is debounced (5s minimum file age) to avoid catching files mid-write.

After completion:

- `aidevops inbox add <path>` copies/moves a file into `_inbox/{auto-detected-source}/` with audit entry.
- `aidevops inbox add --url <url>` saves a page snapshot + URL to `_inbox/web/`.
- Files dropped into `_inbox/_drop/` are detected and queued for triage (status `pending`).
- `triage.log` is append-only JSONL; never modified after write.

## Why

CLI capture is the baseline. Watch folder lets users drag-drop without thinking. Both produce identical audit-log shape so triage (P2c) processes them uniformly.

The audit log is the lossy-classification mitigation: if triage routes wrongly, user can `aidevops inbox find <query>` against the log to recover.

## Tier

**Selected tier:** `tier:standard`. Multi-subcommand helper with filesystem watcher integration. Modeled on `worktree-helper.sh` shape.

## PR Conventions

Child of parent-task t2840. Use `For #20892`.

## How

### Files to Modify

- `EDIT: .agents/scripts/inbox-helper.sh` — add `add`, `watch`, `find` subcommands. (Created in t2866.)
- `NEW: .agents/scripts/inbox-watch-routine.sh` — invoked by pulse or fswatch; processes `_drop/` items (queues for triage, doesn't classify).
- `EDIT: .agents/scripts/aidevops` — wire `aidevops inbox <add|find>` subcommands.
- `NEW: .agents/scripts/test-inbox-capture.sh` — smoke test.

### Implementation Steps

1. `inbox-helper.sh add <path>`:
   - Auto-detect source sub-folder from extension/MIME (.eml → email/, .png/.jpg → scan/, .mp3/.m4a → voice/, http(s):// → web/, otherwise → _drop/)
   - Copy file to target sub-folder with conflict-safe naming (`<orig-stem>_<timestamp>.<ext>`)
   - Append JSONL entry to `triage.log`:
     ```json
     {"ts":"2026-04-25T19:00:00Z","source":"cli-add","sub":"email","orig":"/tmp/foo.eml","path":"_inbox/email/foo_20260425T190000.eml","status":"pending","sensitivity":"unverified"}
     ```
   - Original location: copy if path is outside `_drop/`, move if inside (`_drop/` is staging only).

2. `inbox-helper.sh add --url <url>`:
   - Fetch page (curl or `gh api` if GitHub URL)
   - Save HTML + extracted text + metadata (title, fetched_at) to `_inbox/web/<slug>_<ts>.{html,md,meta.json}`
   - Audit entry as above

3. `inbox-helper.sh find <query>`:
   - Greps `triage.log` for matching JSONL entries
   - Returns list of items routed in last 30 days matching query (filename, original path, plane destination if triaged)

4. `inbox-watch-routine.sh`:
   - Lists files in `_drop/` older than 5 seconds (debounce)
   - For each: run `inbox-helper.sh add <path>` (auto-source-detect) which moves it out of `_drop/`
   - Idempotent — already-processed files are gone from `_drop/`

5. Pulse integration: register `inbox-watch-routine.sh` as a pulse routine running every N minutes (configurable, default 5m).

### Complexity Impact

- **Target function:** none (extending t2866 helper + new routine file)
- **Estimated growth:** ~150 lines added to `inbox-helper.sh`, ~100 lines new in routine
- **Action required:** None — well within thresholds.

### Verification

```bash
shellcheck .agents/scripts/inbox-helper.sh .agents/scripts/inbox-watch-routine.sh
.agents/scripts/test-inbox-capture.sh

# Manual sanity
echo "test content" > /tmp/test-capture.txt
aidevops inbox add /tmp/test-capture.txt
ls _inbox/_drop/  # should contain test-capture_<ts>.txt
grep "cli-add" _inbox/triage.log  # should show JSONL entry
```

### Files Scope

- `.agents/scripts/inbox-helper.sh`
- `.agents/scripts/inbox-watch-routine.sh`
- `.agents/scripts/aidevops`
- `.agents/scripts/test-inbox-capture.sh`

## Acceptance Criteria

- [ ] `aidevops inbox add <file>` copies to correct sub-folder + appends `triage.log`.
- [ ] `aidevops inbox add --url <url>` saves page snapshot + metadata.
- [ ] Files in `_drop/` are processed by `inbox-watch-routine.sh` after 5s debounce.
- [ ] `aidevops inbox find <query>` returns matching audit log entries.
- [ ] All `triage.log` entries have `sensitivity:"unverified"` (until P2c clears them).
- [ ] `shellcheck` clean.

## Context & Decisions

- **Why JSONL not SQLite for audit log:** append-only, grep-friendly, never needs schema migration. SQLite is overkill for a transit-zone log.
- **Why 5s debounce:** typical drag-drop into a folder takes <1s; large file copies can take longer. 5s is conservative — avoids catching mid-write files.
- **Why `_drop/` is move-only:** to give users a "did it work?" feedback (file disappears = captured).
- **Why pulse routine, not always-on fswatch:** keeps install lightweight (no daemon dependency). Users who want sub-minute responsiveness can install fswatch and configure it manually.

## Relevant Files

- `t2866-brief.md` — prerequisite directory contract
- `.agents/scripts/worktree-helper.sh` — multi-subcommand pattern reference
- `.agents/scripts/aidevops` — CLI wire-up

## Dependencies

- **Blocked by:** t2866 (P2a — directory contract)
- **Blocks:** t2868 (P2c — triage processes captured items)
- **External:** none in MVP (URL fetch uses curl; iOS Shortcuts and email forwarding are post-MVP)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | helper pattern + JSONL append patterns |
| Implementation | 3h | 3 subcommands + watch routine |
| Testing | 1h | smoke test + manual verification |
| **Total** | **~4.5h** | |
