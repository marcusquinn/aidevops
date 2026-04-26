# _inbox/ — Transit Zone

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

This directory is a **transit zone**, not permanent storage.

Items here are **unclassified** — they have not yet been routed to a knowledge plane,
assigned a sensitivity level, or deduplicated. Nothing in `_inbox/` is considered
authoritative.

## Sub-folders

| Folder | Purpose |
|--------|---------|
| `_drop/` | Watch folder — drag files here; `inbox-watch-routine.sh` picks them up |
| `email/` | Email captures (`.eml`, `.msg`) |
| `web/` | Web page snapshots (HTML + extracted text + metadata) |
| `scan/` | Document scans and images (`.pdf`, `.png`, `.jpg`, `.heic`, `.tiff`) |
| `voice/` | Voice memos and recordings (`.mp3`, `.m4a`, `.wav`, `.ogg`) |
| `import/` | Bulk imports from other systems |
| `_needs-review/` | Items that failed auto-routing and need manual triage |

## Audit Log

`triage.log` is an append-only JSONL file. Each line records one capture event:

```json
{"ts":"2026-04-25T19:00:00Z","source":"cli-add","sub":"email","orig":"/tmp/foo.eml","path":"_inbox/email/foo_20260425T190000.eml","status":"pending","sensitivity":"unverified"}
```

Fields:
- `ts` — ISO 8601 UTC capture timestamp
- `source` — capture method (`cli-add`, `cli-url`, `drop-watch`)
- `sub` — destination sub-folder
- `orig` — original path or URL
- `path` — current path within `_inbox/`
- `status` — `pending` (awaiting triage), `triaged` (routed), `rejected` (discarded)
- `sensitivity` — `unverified` until P2c triage classifies the item

**Never modify `triage.log` after write.** Use `aidevops inbox find <query>` to search it.

## Security Note

Items with `sensitivity:"unverified"` must NOT be sent to cloud LLMs until P2c
triage classifies them. The LLM routing helper checks plane membership; `_inbox/`
membership implies local-only processing.

## .gitignore

Binary captures are gitignored — only `README.md`, `.gitignore`, and `triage.log`
are tracked. This keeps repos lean while the audit trail is preserved.

## Commands

```bash
# Add a file
aidevops inbox add /path/to/file.eml

# Add a URL (saves page snapshot)
aidevops inbox add --url https://example.com/article

# Watch folder processing (run by pulse routine every 5m)
inbox-watch-routine.sh

# Search the audit log
aidevops inbox find "meeting notes"

# Show counts per sub-folder
aidevops inbox status
```
