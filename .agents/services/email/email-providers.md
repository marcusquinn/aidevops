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

**POP vs IMAP decision**: Use IMAP (default). Use POP only for shared mailboxes where all users must read the same emails.

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Copy template to working config
cp configs/email-providers.json.txt configs/email-providers.json

# Customise provider settings (e.g., Cloudron hostname)
# No credentials in this file — auth is handled per-connection
```

## Provider Selection Guide

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
├── Multiple devices / mobile?
│   └── Use IMAP (sync state across devices)
├── Shared mailbox (info@, support@, sales@)?
│   ├── All users must see ALL emails?
│   │   └── Use POP with "leave on server" + retention window
│   └── Users handle different emails (assign/claim)?
│       └── Use IMAP with shared folder or helpdesk tool
├── Server-side processing (rules, filters)?
│   └── Use IMAP (server-side folders and flags)
├── Archival / backup only?
│   └── Use POP (download and store locally)
└── Default choice
    └── Use IMAP
```

**When POP makes sense**: Shared mailboxes (info@, support@) where multiple users need to read the same emails independently. POP downloads a copy to each client. Configure "leave on server" with a 30-90 day retention window so all clients can download.

**When POP is wrong**: Mobile devices, multi-device users, or when folder organisation matters. POP has no concept of folders, flags, or synchronised read/unread state.

## JMAP (Modern Alternative)

JMAP (JSON Meta Application Protocol, RFC 8620/8621) is the modern replacement for IMAP:

- **Stateless**: No persistent connection required (unlike IMAP)
- **Efficient**: Binary-safe, push-capable, lower bandwidth
- **JSON-based**: Easy to integrate programmatically
- **Current support**: Fastmail (reference implementation). Limited adoption elsewhere.

For new integrations where Fastmail is the provider, prefer JMAP over IMAP. For all other providers, use IMAP.

## Folder Name Mapping

Different providers use different names for standard folders. This causes silent failures when scripts assume a folder name.

| Folder | Gmail | Outlook/365 | Yahoo | iCloud | Most Others |
|--------|-------|-------------|-------|--------|-------------|
| Inbox | `INBOX` | `Inbox` | `Inbox` | `INBOX` | `INBOX` |
| Sent | `[Gmail]/Sent Mail` | `Sent` / `Sent Items` | `Sent` | `Sent Messages` | `Sent` |
| Drafts | `[Gmail]/Drafts` | `Drafts` | `Draft` | `Drafts` | `Drafts` |
| Trash | `[Gmail]/Trash` | `Deleted` / `Deleted Items` | `Trash` | `Deleted Messages` | `Trash` |
| Spam/Junk | `[Gmail]/Spam` | `Junk` / `Junk Email` | `Bulk Mail` | `Junk` | `Junk` or `Spam` |
| Archive | `[Gmail]/All Mail` | `Archive` | `Archive` | `Archive` | `Archive` |

**Gmail special behaviour**: Gmail uses labels, not folders. A message can have multiple labels and appear in multiple IMAP "folders" simultaneously. Deleting from one label removes the label, not the message. True deletion requires moving to Trash.

**Outlook/365 difference**: Free Outlook.com uses `Sent` and `Deleted`. Microsoft 365 business uses `Sent Items` and `Deleted Items`.

## Shared Mailbox Patterns

Common shared mailbox addresses and their typical use:

| Address | Purpose | Typical Protocol |
|---------|---------|-----------------|
| `info@` | General enquiries | POP or IMAP shared |
| `support@` | Customer support | IMAP + helpdesk tool |
| `sales@` | Sales enquiries | IMAP + CRM |
| `enquiries@` | General enquiries (UK) | POP or IMAP shared |
| `accounts@` | Financial / billing | IMAP (restricted access) |
| `marketing@` | Marketing team | IMAP shared |
| `admin@` | Administrative | IMAP (restricted access) |
| `webmaster@` | Website issues | IMAP |
| `buyers@` | Procurement | IMAP |
| `dataprotection@` | GDPR / privacy | IMAP (restricted access) |
| `legal@` | Legal matters | IMAP (restricted access) |
| `billing@` | Payment / invoicing | IMAP (restricted access) |
| `noreply@` | Outbound only | SMTP only (no inbox needed) |
| `hello@` | Friendly general contact | POP or IMAP shared |
| `contact@` | General contact | POP or IMAP shared |
| `hr@` | Human resources | IMAP (restricted access) |
| `careers@` | Job applications | IMAP |
| `press@` | Media enquiries | IMAP |
| `abuse@` | Abuse reports (RFC 2142) | IMAP |
| `postmaster@` | Mail server issues (RFC 2142) | IMAP |
| `security@` | Security reports | IMAP (restricted access) |

### Provider-Specific Shared Mailbox Support

- **Microsoft 365**: Best-in-class. Dedicated shared mailbox feature, no extra license, auto-mapping, send-as, send-on-behalf.
- **Google Workspace**: Collaborative inboxes via Google Groups. Delegated access for individual mailboxes.
- **Zoho Mail**: Group mailboxes in paid plans. Shared folders and delegated access.
- **Cloudron**: Create separate mailbox accounts or aliases via admin panel / CLI.
- **Proton Mail**: Business plans support multi-user access and catch-all.
- **Others**: Most free/personal providers have no shared mailbox support.

## Cloudron Mail Management

```bash
# List all mailboxes
cloudron mail list

# Add a mailbox
cloudron mail add user@yourdomain.com

# Remove a mailbox
cloudron mail remove user@yourdomain.com

# List aliases
cloudron mail aliases

# Add alias
cloudron mail alias-add alias@yourdomain.com target@yourdomain.com

# Enable catch-all for a domain
cloudron mail catch-all yourdomain.com target@yourdomain.com
```

## Provider-Specific Notes

### Gmail / Google Workspace

- IMAP must be enabled in Settings > Forwarding and POP/IMAP
- OAuth2 required since May 2022 (app passwords available with 2FA)
- Labels map to IMAP folders under `[Gmail]/` prefix
- Sending limits: 500/day (Gmail), 2000/day (Workspace)

### Microsoft 365

- Basic auth fully deprecated since October 2022
- OAuth2 via Microsoft Entra ID (formerly Azure AD)
- Graph API is the recommended programmatic access method
- Shared mailboxes are free (no license required)

### Proton Mail

- Requires Proton Mail Bridge running locally
- Bridge provides local IMAP (1143) and SMTP (1025) endpoints
- Bridge generates its own password — do not use account password
- Not suitable for headless/server environments without Bridge CLI

### Tuta (Tutanota)

- No IMAP, SMTP, POP3, or any standard protocol support
- Access only through Tuta's own apps (web, desktop, mobile)
- Cannot be used with third-party email clients
- This is a deliberate security decision for their encryption architecture

### Zoho Mail

- IMAP must be explicitly enabled in settings
- Regional domains affect server hostnames (zoho.com, zoho.eu, zoho.in, zoho.com.au, zoho.jp)
- Free tier: up to 5 users, 5GB each

## Related

- `services/email/ses.md` — Amazon SES for outbound email delivery
- `services/email/email-agent.md` — Autonomous email agent for mission communication
- `services/email/email-testing.md` — Email deliverability testing
- `configs/email-providers.json.txt` — Provider configuration template

---

*Provider settings verified against documentation as of 2026-03. Privacy ratings informed by privacytools.io and tosdr.org data. Settings may change — verify against provider documentation for production use.*
