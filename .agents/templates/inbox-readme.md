<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# _inbox/ — Transit Zone

This directory is a **transit zone**: captures land here first, then triage
routes them to the appropriate knowledge plane or discards them.

> **Sensitivity contract:** Nothing in `_inbox/` may be sent to cloud LLMs
> until triage assigns a sensitivity label. The LLM routing helper treats
> `_inbox/` membership as `local-only` by default. After classification
> (P2c), items move to their target plane and inherit that plane's sensitivity
> baseline.

## Sub-folders

| Folder | Purpose |
|--------|---------|
| `_drop/` | General-purpose drop — quick paste, text snippets, anything uncategorised |
| `email/` | Email captures — forwarded messages, exported threads |
| `web/` | Web captures — saved HTML, PDFs, screenshots |
| `scan/` | Scanned documents awaiting OCR / classification |
| `voice/` | Voice memos and audio transcripts |
| `import/` | Bulk imports from external sources |
| `_needs-review/` | Items flagged as requiring manual review before routing |

## Triage Log

`triage.log` is a JSONL audit file recording routing decisions. Each line:

```json
{"ts":"ISO8601","file":"path","action":"routed|discarded","target":"plane/subfolder","sensitivity":"unverified|public|private|privileged"}
```

Do not edit `triage.log` by hand — append via the triage CLI (P2c).

## .gitignore Contract

`_inbox/.gitignore` excludes all binary and bulk content (PDFs, audio, images,
HTML). Only `README.md`, `.gitignore`, and `triage.log` are committed:
- `README.md` — visibility (users see the inbox in the repo)
- `.gitignore` — self-documenting policy
- `triage.log` — audit trail for routing decisions

When triage routes an item to a plane, it is copied or moved out of `_inbox/`.
The target plane applies its own `.gitignore` policy.

## What Does Not Belong Here

- Final classified content — move to the target plane
- Secrets or credentials — use `aidevops secret set`
- Build artefacts or generated files — use `.gitignore` at repo root

## Provisioning

```bash
# Provision this repo's inbox:
inbox-helper.sh provision .

# Provision the workspace-level cross-repo inbox:
inbox-helper.sh provision-workspace

# Check status:
inbox-helper.sh status .

# Validate structure:
inbox-helper.sh validate .
```
