<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1525: JMAP adapter for Fastmail and compatible providers

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 4 polish)

## What

Add JMAP (RFC 8620/8621) adapter to email-mailbox-helper.sh for Fastmail and other JMAP-compatible providers. JMAP is stateful, push-capable, and structured JSON — dramatically simpler than IMAP's line protocol.

## Acceptance Criteria

- [ ] JMAP adapter in email_imap_adapter.py (or separate email_jmap_adapter.py)
- [ ] Works with Fastmail JMAP endpoint
- [ ] Push notification support for new mail

## Dependencies

- **Blocked by:** t1493 (mailbox helper — IMAP adapter first)
- **External:** Fastmail account for testing

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 4h | JMAP adapter + push support |
| **Total** | **4h** | |
