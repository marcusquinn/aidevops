---
description: Email provider configuration templates, privacy ratings, and protocol guidance
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
---

# Email Provider Configuration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Config**: `configs/email-providers.json` (from `.json.txt` template)
- **Providers**: 19 providers — Cloudron, Gmail, Google Workspace, Outlook, Microsoft 365, Proton Mail, Fastmail, mailbox.org, Tuta, Yahoo, Zoho, GMX, IONOS, Namecheap, mail.com, StartMail, Disroot, ChatMail, iCloud
- **Protocols**: IMAP (993/TLS), SMTP (465/TLS or 587/STARTTLS), POP3 (995/TLS), JMAP (Fastmail only)
- **Privacy tiers**: A+ (Proton, Tuta, Cloudron) > A (Fastmail, mailbox.org, StartMail, Disroot, ChatMail) > B (Zoho, IONOS, Namecheap, iCloud) > C (Google Workspace, Microsoft 365, GMX, mail.com) > D (Gmail, Outlook, Yahoo)
- **JMAP**: Only Fastmail has production JMAP support (RFC 8620/8621 reference implementation)
- **No standard protocols**: Tuta — proprietary client only, no IMAP/SMTP

**POP vs IMAP**: Use IMAP (default). Use POP only for shared mailboxes where all users must read the same emails.

<!-- AI-CONTEXT-END -->

## Setup

```bash
cp configs/email-providers.json.txt configs/email-providers.json
# Customise provider settings (e.g., Cloudron hostname). No credentials in this file.
```

## POP vs IMAP Decision Tree

```text
Need email access?
├── Multiple devices / mobile? → IMAP (sync state across devices)
├── Shared mailbox (info@, support@)?
│   ├── All users must see ALL emails? → POP with "leave on server" + 30-90 day retention
│   └── Users handle different emails? → IMAP with shared folder or helpdesk tool
├── Server-side processing (rules, filters)? → IMAP
├── Archival / backup only? → POP (download and store locally)
└── Default → IMAP
```

**Never use POP for**: mobile, multi-device, or when folder organisation matters — POP has no folders, flags, or sync.

## JMAP (Modern Alternative)

JMAP (RFC 8620/8621) replaces IMAP: stateless, JSON-based, push-capable, lower bandwidth. Currently Fastmail only. For Fastmail integrations, prefer JMAP over IMAP.

## Folder Name Mapping

Different providers use different names for standard folders — causes silent failures when scripts assume a name.

| Folder | Gmail | Outlook/365 | Yahoo | iCloud | Most Others |
|--------|-------|-------------|-------|--------|-------------|
| Inbox | `INBOX` | `Inbox` | `Inbox` | `INBOX` | `INBOX` |
| Sent | `[Gmail]/Sent Mail` | `Sent` / `Sent Items` | `Sent` | `Sent Messages` | `Sent` |
| Drafts | `[Gmail]/Drafts` | `Drafts` | `Draft` | `Drafts` | `Drafts` |
| Trash | `[Gmail]/Trash` | `Deleted` / `Deleted Items` | `Trash` | `Deleted Messages` | `Trash` |
| Spam/Junk | `[Gmail]/Spam` | `Junk` / `Junk Email` | `Bulk Mail` | `Junk` | `Junk` or `Spam` |
| Archive | `[Gmail]/All Mail` | `Archive` | `Archive` | `Archive` | `Archive` |

- **Gmail**: Uses labels, not folders. Messages can have multiple labels. Deleting from one label removes the label, not the message. True deletion requires Trash.
- **Outlook/365**: Free Outlook.com uses `Sent`/`Deleted`. Microsoft 365 business uses `Sent Items`/`Deleted Items`.

## Shared Mailbox Support

Shared mailbox addresses (`info@`, `support@`, `noreply@`, etc.) are listed in `configs/email-providers.json.txt` under `shared_mailbox_patterns`.

**Provider capabilities:**

- **Microsoft 365**: Best-in-class — dedicated shared mailbox (no extra license), auto-mapping, send-as, send-on-behalf
- **Google Workspace**: Collaborative inboxes via Google Groups, delegated access
- **Zoho Mail**: Group mailboxes in paid plans, shared folders, delegated access
- **Cloudron**: Separate mailbox accounts or aliases via admin panel / CLI
- **Proton Mail**: Business plans support multi-user access and catch-all
- **Others**: Most free/personal providers have no shared mailbox support

## Cloudron Mail Management

```bash
cloudron mail list                                              # List mailboxes
cloudron mail add user@yourdomain.com                           # Add mailbox
cloudron mail remove user@yourdomain.com                        # Remove mailbox
cloudron mail aliases                                           # List aliases
cloudron mail alias-add alias@yourdomain.com target@yourdomain.com  # Add alias
cloudron mail catch-all yourdomain.com target@yourdomain.com    # Enable catch-all
```

## Provider-Specific Notes

**Gmail / Google Workspace** — IMAP must be enabled in Settings. OAuth2 required since May 2022 (app passwords available with 2FA). Labels map to IMAP folders under `[Gmail]/` prefix. Sending limits: 500/day (Gmail), 2000/day (Workspace).

**Microsoft 365** — Basic auth fully deprecated since October 2022. OAuth2 via Microsoft Entra ID. Graph API is the recommended programmatic access method. Shared mailboxes are free (no license).

**Proton Mail** — Requires Proton Mail Bridge running locally (IMAP 1143, SMTP 1025). Bridge generates its own password — do not use account password. Not suitable for headless/server environments without Bridge CLI.

**Tuta** — No IMAP, SMTP, POP3, or any standard protocol. Access only through Tuta's own apps. Deliberate security decision for their encryption architecture.

**Zoho Mail** — IMAP must be explicitly enabled. Regional domains affect hostnames (zoho.com, zoho.eu, zoho.in, zoho.com.au, zoho.jp). Free tier: up to 5 users, 5GB each.

## Related

- `services/email/ses.md` — Amazon SES for outbound email delivery
- `services/email/email-agent.md` — Autonomous email agent for mission communication
- `services/email/email-testing.md` — Email deliverability testing
- `configs/email-providers.json.txt` — Provider configuration template (server settings, auth methods, privacy ratings, protocol support)

---

*Provider settings verified against documentation as of 2026-03. Privacy ratings informed by privacytools.io and tosdr.org data.*
