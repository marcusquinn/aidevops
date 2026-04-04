<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1522: macOS Spotlight / notmuch integration for mailbox search

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 4 polish)

## What

Integrate macOS Spotlight for efficient mailbox search including attachment content. Linux equivalent: `notmuch` or `mu` for indexed email search. Leverage existing OS-level indexes rather than building custom search.

## Acceptance Criteria

- [ ] Spotlight search integration for macOS (mdfind for email content)
- [ ] notmuch/mu guidance for Linux users
- [ ] Attachment content searchable

## Dependencies

- **Blocked by:** t1493 (mailbox helper)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 2.5h | Spotlight + notmuch integration |
| **Total** | **2.5h** | |
