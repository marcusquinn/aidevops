<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1509: Legal case file assembly — export email threads to PDF with attachments

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 2 actions)
- **Conversation context:** Email history and logs could become or be needed for building legal case files, including exporting to PDFs/txt files with attachments.

## What

Create `scripts/email-export-helper.sh` that:

1. Exports email threads to PDF or text files with full headers and metadata
2. Includes attachments organized in a folder structure
3. Preserves chain of custody metadata (timestamps, message-ids, sender verification)
4. Creates IMAP folders for archiving case-related emails
5. Generates index/manifest of exported materials

## Why

Legal proceedings require complete, verifiable email records. Ad-hoc exports lose metadata and attachments. A structured export preserves evidentiary value.

## How (Approach)

- Shell script using email-mailbox-helper.sh for message retrieval
- Existing email-to-markdown pipeline for content extraction
- pandoc for markdown→PDF conversion
- Folder structure: `case-name/threads/`, `case-name/attachments/`, `case-name/manifest.md`

## Acceptance Criteria

- [ ] `scripts/email-export-helper.sh` exists and passes ShellCheck
- [ ] Exports threads with full headers and metadata
- [ ] Includes attachments in organized folder structure
- [ ] Generates manifest/index file

## Dependencies

- **Blocked by:** t1493 (mailbox helper), t1508 (actions guidance)
- **Blocks:** none
- **External:** pandoc for PDF generation

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 3.5h | Export pipeline + folder structure + manifest |
| Testing | 1h | Test with real email threads |
| **Total** | **4.5h** | |
