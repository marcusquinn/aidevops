<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1526: Microsoft Graph API adapter for Outlook/365 shared mailboxes

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 4 polish)

## What

Add Microsoft Graph API adapter for Outlook/365 shared mailboxes. Graph API provides richer shared mailbox operations than IMAP (delegation, permissions, categories).

## Acceptance Criteria

- [ ] Graph API adapter for Outlook/365 mail operations
- [ ] Shared mailbox delegation support
- [ ] OAuth2 authentication flow

## Dependencies

- **Blocked by:** t1493 (mailbox helper)
- **External:** Microsoft 365 account, Azure AD app registration

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 5h | Graph API adapter + OAuth flow |
| **Total** | **5h** | |
