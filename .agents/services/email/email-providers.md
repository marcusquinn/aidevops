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

| Rating | Providers | Auth |
|--------|-----------|------|
| **A+** Proton Mail, Tuta, Cloudron | E2EE/self-hosted, zero-knowledge | Bridge password / regular |
| **A** Fastmail, mailbox.org, StartMail, Disroot, ChatMail | No data mining, privacy-focused | App passwords / regular |
| **B** Zoho, IONOS, Namecheap, iCloud | No ads, less privacy-focused jurisdiction | OAuth2 / app passwords |
| **C** Google Workspace, Microsoft 365, GMX, mail.com | No ad targeting, telemetry active | OAuth2 / service account |
| **D** Gmail, Outlook/Hotmail, Yahoo | Ad-supported, content scanning | OAuth2 / app passwords |

**Protocol exceptions**: Tuta — no IMAP/SMTP/POP3 (proprietary only). Proton Mail — IMAP/SMTP via local Bridge. Fastmail — JMAP available. Outlook/365 — Graph API. All others: IMAP + SMTP + POP3.

## POP vs IMAP

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

- **Gmail**: labels not folders — message can appear in multiple IMAP "folders". Deleting a label removes the label only; true deletion requires moving to Trash.
- **Outlook/365**: free uses `Sent`/`Deleted`; Microsoft 365 business uses `Sent Items`/`Deleted Items`.

## Shared Mailbox Patterns

| Address | Protocol | Notes |
|---------|----------|-------|
| `info@`, `enquiries@`, `hello@`, `contact@` | POP or IMAP shared | POP if all users need same copy |
| `support@` | IMAP + helpdesk tool | Assign/claim workflow |
| `sales@` | IMAP + CRM | |
| `noreply@` | SMTP only | No inbox needed |
| `abuse@`, `postmaster@` | IMAP | RFC 2142 required addresses |
| `security@`, `dataprotection@`, `legal@`, `billing@`, `accounts@` | IMAP (restricted) | Limit access |

**Shared mailbox provider support**: Microsoft 365 (best — dedicated shared mailbox, no extra license, send-as/on-behalf) > Google Workspace (Groups + delegated access) > Zoho Mail (paid plans) > Cloudron (aliases via CLI) > Proton Mail (business plans). Most free/personal providers: none.

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
