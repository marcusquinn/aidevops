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
- **Providers**: 19 — Cloudron, Gmail, Google Workspace, Outlook, Microsoft 365, Proton Mail, Fastmail, mailbox.org, Tuta, Yahoo, Zoho, GMX, IONOS, Namecheap, mail.com, StartMail, Disroot, ChatMail, iCloud
- **Protocols**: IMAP (993/TLS), SMTP (465/TLS or 587/STARTTLS), POP3 (995/TLS), JMAP (Fastmail only)
- **Privacy tiers**: A+ (Proton, Tuta, Cloudron) > A (Fastmail, mailbox.org, StartMail, Disroot, ChatMail) > B (Zoho, IONOS, Namecheap, iCloud) > C (Google Workspace, Microsoft 365, GMX, mail.com) > D (Gmail, Outlook, Yahoo)
- **JMAP**: Fastmail only (RFC 8620/8621). Prefer over IMAP for new Fastmail integrations.
- **No standard protocols**: Tuta — proprietary client only

**POP vs IMAP**: Use IMAP (default). POP only for shared mailboxes where all users must read the same emails.

<!-- AI-CONTEXT-END -->

## Setup

```bash
cp configs/email-providers.json.txt configs/email-providers.json
# Customise provider settings (e.g., Cloudron hostname)
# No credentials in this file — auth is handled per-connection
```

## Provider Selection

### By Privacy Rating

| Rating | Providers | Key Characteristics |
|--------|-----------|-------------------|
| A+ | Proton Mail, Tuta, Cloudron | E2EE built-in or self-hosted, zero-knowledge, open-source |
| A | Fastmail, mailbox.org, StartMail, Disroot, ChatMail | No data mining, privacy-focused business model |
| B | Zoho, IONOS, Namecheap, iCloud | No ads/mining, but less privacy-focused jurisdiction or practices |
| C | Google Workspace, Microsoft 365, GMX, mail.com | Business plans with no ad targeting, but telemetry active |
| D | Gmail, Outlook/Hotmail, Yahoo | Ad-supported, content scanning, broad data usage policies |

### By Protocol Support

| Protocol | Providers |
|----------|-----------|
| IMAP + SMTP | All except Tuta |
| JMAP | Fastmail only |
| POP3 | Gmail, Google Workspace, Outlook, Microsoft 365, Yahoo, Zoho, GMX, IONOS, Namecheap, mail.com, Fastmail, mailbox.org, Disroot, Cloudron |
| Graph API | Outlook, Microsoft 365 |
| Bridge required | Proton Mail (local IMAP/SMTP via Proton Bridge) |
| No standard protocols | Tuta (proprietary client only) |

### By Auth Method

| Method | Providers |
|--------|-----------|
| OAuth2 | Gmail, Google Workspace, Outlook, Microsoft 365, Zoho |
| App passwords | Gmail, Fastmail, Yahoo, StartMail, iCloud |
| Regular password | Cloudron, mailbox.org, GMX, IONOS, Namecheap, mail.com, Disroot, ChatMail, Zoho |
| Bridge password | Proton Mail |
| Service account | Google Workspace, Microsoft 365 |

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

**POP wrong for**: mobile, multi-device, folder organisation (no folder/flag/read-state sync).

## Folder Name Mapping

| Folder | Gmail | Outlook/365 | Yahoo | iCloud | Most Others |
|--------|-------|-------------|-------|--------|-------------|
| Inbox | `INBOX` | `Inbox` | `Inbox` | `INBOX` | `INBOX` |
| Sent | `[Gmail]/Sent Mail` | `Sent` / `Sent Items` | `Sent` | `Sent Messages` | `Sent` |
| Drafts | `[Gmail]/Drafts` | `Drafts` | `Draft` | `Drafts` | `Drafts` |
| Trash | `[Gmail]/Trash` | `Deleted` / `Deleted Items` | `Trash` | `Deleted Messages` | `Trash` |
| Spam/Junk | `[Gmail]/Spam` | `Junk` / `Junk Email` | `Bulk Mail` | `Junk` | `Junk` or `Spam` |
| Archive | `[Gmail]/All Mail` | `Archive` | `Archive` | `Archive` | `Archive` |

- **Gmail**: uses labels, not folders — a message can appear in multiple IMAP "folders". Deleting from a label removes the label only; true deletion requires moving to Trash.
- **Outlook/365**: free Outlook.com uses `Sent`/`Deleted`; Microsoft 365 business uses `Sent Items`/`Deleted Items`.

## Shared Mailbox Patterns

| Address | Purpose | Typical Protocol |
|---------|---------|-----------------|
| `info@` | General enquiries | POP or IMAP shared |
| `support@` | Customer support | IMAP + helpdesk tool |
| `sales@` | Sales enquiries | IMAP + CRM |
| `enquiries@` | General enquiries (UK) | POP or IMAP shared |
| `accounts@` | Financial / billing | IMAP (restricted) |
| `marketing@` | Marketing team | IMAP shared |
| `admin@` | Administrative | IMAP (restricted) |
| `webmaster@` | Website issues | IMAP |
| `buyers@` | Procurement | IMAP |
| `dataprotection@` | GDPR / privacy | IMAP (restricted) |
| `legal@` | Legal matters | IMAP (restricted) |
| `billing@` | Payment / invoicing | IMAP (restricted) |
| `noreply@` | Outbound only | SMTP only |
| `hello@` | Friendly general contact | POP or IMAP shared |
| `contact@` | General contact | POP or IMAP shared |
| `hr@` | Human resources | IMAP (restricted) |
| `careers@` | Job applications | IMAP |
| `press@` | Media enquiries | IMAP |
| `abuse@` | Abuse reports (RFC 2142) | IMAP |
| `postmaster@` | Mail server issues (RFC 2142) | IMAP |
| `security@` | Security reports | IMAP (restricted) |

**Provider shared mailbox support:**
- **Microsoft 365**: Best-in-class — dedicated shared mailbox, no extra license, auto-mapping, send-as/on-behalf.
- **Google Workspace**: Collaborative inboxes via Google Groups; delegated access for individual mailboxes.
- **Zoho Mail**: Group mailboxes in paid plans; shared folders and delegated access.
- **Cloudron**: Separate mailbox accounts or aliases via admin panel / CLI.
- **Proton Mail**: Business plans support multi-user access and catch-all.
- **Others**: Most free/personal providers have no shared mailbox support.

## Cloudron Mail Management

```bash
cloudron mail list
cloudron mail add user@yourdomain.com
cloudron mail remove user@yourdomain.com
cloudron mail aliases
cloudron mail alias-add alias@yourdomain.com target@yourdomain.com
cloudron mail catch-all yourdomain.com target@yourdomain.com
```

## Provider-Specific Notes

| Provider | Key Notes |
|----------|-----------|
| **Gmail / Google Workspace** | Enable IMAP in Settings > Forwarding and POP/IMAP. OAuth2 required since May 2022 (app passwords with 2FA). Labels map to `[Gmail]/` IMAP folders. Limits: 500/day (Gmail), 2000/day (Workspace). |
| **Microsoft 365** | Basic auth deprecated Oct 2022. OAuth2 via Microsoft Entra ID. Graph API recommended for programmatic access. Shared mailboxes free (no license). |
| **Proton Mail** | Requires Proton Bridge running locally (local IMAP 1143, SMTP 1025). Use Bridge-generated password, not account password. Not suitable for headless/server without Bridge CLI. |
| **Tuta** | No IMAP/SMTP/POP3. Tuta apps only (web, desktop, mobile). Deliberate security decision for encryption architecture. |
| **Zoho Mail** | Enable IMAP in settings. Regional domains affect hostnames (zoho.com, zoho.eu, zoho.in, zoho.com.au, zoho.jp). Free tier: 5 users, 5 GB each. |

## Related

- `services/email/ses.md` — Amazon SES for outbound delivery
- `services/email/email-agent.md` — Autonomous email agent
- `services/email/email-testing.md` — Deliverability testing
- `configs/email-providers.json.txt` — Provider configuration template

---

*Settings verified 2026-03. Privacy ratings from privacytools.io / tosdr.org. Verify against provider docs for production use.*
