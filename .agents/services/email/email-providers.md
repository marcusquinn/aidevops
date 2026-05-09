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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Email Provider Configuration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Config**: `configs/email-providers.json` (from `.json.txt` template)
- **Providers**: 19 — Cloudron, Gmail, Google Workspace, Outlook, Microsoft 365, Proton Mail, Fastmail, mailbox.org, Tuta, Yahoo, Zoho, GMX, IONOS, Namecheap, mail.com, StartMail, Disroot, ChatMail, iCloud
- **Protocols**: IMAP (993/TLS), SMTP (465/TLS or 587/STARTTLS), POP3 (995/TLS), JMAP (Fastmail only)
- **Privacy**: A+ (Proton, Tuta, Cloudron) > A (Fastmail, mailbox.org, StartMail, Disroot, ChatMail) > B (Zoho, IONOS, Namecheap, iCloud) > C (GWS, M365, GMX, mail.com) > D (Gmail, Outlook, Yahoo)
- **Default protocol**: IMAP. POP only for shared mailboxes where all users must read the same emails.

<!-- AI-CONTEXT-END -->

## Setup

```bash
cp configs/email-providers.json.txt configs/email-providers.json
# Customise provider settings (e.g., Cloudron hostname). No credentials here — auth is per-connection.
```

## Provider Selection

### By Privacy Rating

| Rating | Providers | Characteristics |
|--------|-----------|-----------------|
| A+ | Proton Mail, Tuta, Cloudron | E2EE / self-hosted, zero-knowledge, open-source |
| A | Fastmail, mailbox.org, StartMail, Disroot, ChatMail | No data mining, privacy-focused model |
| B | Zoho, IONOS, Namecheap, iCloud | No ads/mining; less privacy-focused jurisdiction |
| C | Google Workspace, Microsoft 365, GMX, mail.com | Business plans without ad targeting; telemetry active |
| D | Gmail, Outlook/Hotmail, Yahoo | Ad-supported, content scanning, broad data usage |

### By Protocol Support

| Protocol | Providers | Notes |
|----------|-----------|-------|
| IMAP + SMTP | All except Tuta | Gmail: enable in Settings > Forwarding and POP/IMAP. Zoho: enable in settings; regional hostnames (zoho.com/eu/in/com.au/jp) |
| JMAP | Fastmail | RFC 8620/8621 — prefer over IMAP for new Fastmail integrations |
| POP3 | Gmail, GWS, Outlook, M365, Yahoo, Zoho, GMX, IONOS, Namecheap, mail.com, Fastmail, mailbox.org, Disroot, Cloudron | |
| Graph API | Outlook, Microsoft 365 | Recommended for programmatic access |
| Bridge required | Proton Mail | Local IMAP 1143 / SMTP 1025 via Proton Bridge (use Bridge-generated password). Not suitable for headless without Bridge CLI |
| No standard protocols | Tuta | Proprietary client only — deliberate design for encryption architecture |

### By Auth Method

| Method | Providers | Notes |
|--------|-----------|-------|
| OAuth2 | Gmail, GWS, Outlook, M365, Zoho | Gmail/GWS: required since May 2022. M365: basic auth deprecated Oct 2022 (OAuth2 via Entra ID) |
| App passwords | Gmail, Fastmail, Yahoo, StartMail, iCloud | |
| Regular password | Cloudron, mailbox.org, GMX, IONOS, Namecheap, mail.com, Disroot, ChatMail, Zoho | |
| Bridge password | Proton Mail | |
| Service account | Google Workspace, Microsoft 365 | |

**Send limits:** Gmail 500/day, Google Workspace 2000/day. Zoho free: 5 users, 5 GB each.

## POP vs IMAP Decision Tree

```text
Need email access?
├── Multiple devices / mobile?         → IMAP
├── Shared mailbox (info@, support@)?
│   ├── All users must see ALL emails? → POP + "leave on server" (30-90 day retention)
│   └── Users handle different emails? → IMAP + shared folder or helpdesk tool
├── Server-side rules/filters?         → IMAP
├── Archival / backup only?            → POP
└── Default                            → IMAP
```

POP does not sync folders, flags, or read-state across devices.

## Folder Name Mapping

| Folder | Gmail | Outlook/365 | Yahoo | iCloud | Most Others |
|--------|-------|-------------|-------|--------|-------------|
| Inbox | `INBOX` | `Inbox` | `Inbox` | `INBOX` | `INBOX` |
| Sent | `[Gmail]/Sent Mail` | `Sent` / `Sent Items` | `Sent` | `Sent Messages` | `Sent` |
| Drafts | `[Gmail]/Drafts` | `Drafts` | `Draft` | `Drafts` | `Drafts` |
| Trash | `[Gmail]/Trash` | `Deleted` / `Deleted Items` | `Trash` | `Deleted Messages` | `Trash` |
| Spam/Junk | `[Gmail]/Spam` | `Junk` / `Junk Email` | `Bulk Mail` | `Junk` | `Junk` or `Spam` |
| Archive | `[Gmail]/All Mail` | `Archive` | `Archive` | `Archive` | `Archive` |

Gmail uses labels, not folders — deleting from a label removes the label only; move to Trash for true deletion. Outlook.com uses `Sent`/`Deleted`; M365 business uses `Sent Items`/`Deleted Items`.

## Shared Mailbox Patterns

| Category | Addresses | Protocol |
|----------|-----------|----------|
| General enquiries | `info@`, `hello@`, `contact@`, `enquiries@` | POP or IMAP shared |
| Customer-facing teams | `support@` (+ helpdesk), `sales@` (+ CRM), `marketing@`, `hr@`, `careers@` | IMAP |
| Restricted / compliance | `accounts@`, `billing@`, `admin@`, `dataprotection@`, `legal@`, `security@` | IMAP (restricted) |
| Outbound only | `noreply@` | SMTP only |
| RFC 2142 / ops | `abuse@`, `postmaster@`, `press@`, `webmaster@`, `buyers@` | IMAP |

**Shared mailbox support:** M365: dedicated shared mailbox (no extra license, auto-mapping, send-as/on-behalf). GWS: collaborative inboxes via Groups + delegated access. Zoho: group mailboxes (paid). Cloudron: separate accounts or aliases via admin/CLI. Proton: multi-user + catch-all (business plans). Others: limited/no native support — check provider docs for alias/forwarding workarounds.

## Cloudron Mail Management

```bash
cloudron mail {list|add|remove} [user@yourdomain.com]
cloudron mail aliases
cloudron mail alias-add alias@yourdomain.com target@yourdomain.com
cloudron mail catch-all yourdomain.com target@yourdomain.com
```

## Related

- `services/email/ses.md` — Amazon SES for outbound delivery
- `services/email/email-agent.md` — Autonomous email agent
- `services/email/email-testing.md` — Deliverability testing
- `configs/email-providers.json.txt` — Provider configuration template

*Settings verified 2026-03. Privacy ratings from privacytools.io / tosdr.org. Verify against provider docs for production use.*
