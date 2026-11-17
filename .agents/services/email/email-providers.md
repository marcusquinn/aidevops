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
- **Providers**: 21 — Cloudron, Gmail, Google Workspace, Outlook, Microsoft 365, Proton Mail, Fastmail, Purelymail, mailbox.org, Tuta, Yahoo, Zoho, GMX, IONOS, Namecheap, Hostinger, mail.com, StartMail, Disroot, ChatMail, iCloud
- **Protocols**: IMAP (993/TLS), SMTP (465/TLS or 587/STARTTLS), POP3 (995/TLS), JMAP (Fastmail only)
- **Privacy**: A+ (Proton, Tuta, Cloudron) > A (Fastmail, mailbox.org, StartMail, Disroot, ChatMail) > B (Purelymail, Zoho, IONOS, Namecheap, iCloud) > C (GWS, M365, GMX, mail.com, Hostinger) > D (Gmail, Outlook, Yahoo)
- **Provisioning helpers**: Purelymail domains, DNS, mailboxes and routing via `purelymail-helper.sh` (`services/email/purelymail.md`)
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
| B | Purelymail, Zoho, IONOS, Namecheap, iCloud | No ads/mining; less privacy-focused jurisdiction |
| C | Google Workspace, Microsoft 365, GMX, mail.com, Hostinger | Business plans without ad targeting; telemetry active |
| D | Gmail, Outlook/Hotmail, Yahoo | Ad-supported, content scanning, broad data usage |

### By Protocol Support

| Protocol | Providers | Notes |
|----------|-----------|-------|
| IMAP + SMTP | All except Tuta | Gmail: enable in Settings > Forwarding and POP/IMAP. Zoho: enable in settings; regional hostnames (zoho.com/eu/in/com.au/jp) |
| JMAP | Fastmail | RFC 8620/8621 — prefer over IMAP for new Fastmail integrations |
| POP3 | Gmail, GWS, Outlook, M365, Yahoo, Zoho, GMX, IONOS, Namecheap, Hostinger, mail.com, Fastmail, Purelymail, mailbox.org, Disroot, Cloudron | |
| Graph API | Outlook, Microsoft 365 | Recommended for programmatic access |
| Bridge required | Proton Mail | Local IMAP 1143 / SMTP 1025 via Proton Bridge (use Bridge-generated password). Not suitable for headless without Bridge CLI |
| No standard protocols | Tuta | Proprietary client only — deliberate design for encryption architecture |

### By Auth Method

| Method | Providers | Notes |
|--------|-----------|-------|
| OAuth2 | Gmail, GWS, Outlook, M365, Zoho | Gmail/GWS: required since May 2022. M365: basic auth deprecated Oct 2022 (OAuth2 via Entra ID) |
| App passwords | Gmail, Fastmail, Purelymail, Yahoo, StartMail, iCloud | Purelymail: required for IMAP/SMTP once 2FA is on; the account admin creates them under **Users**, and only the portal can scope them (IMAP-only, SMTP-only). See `services/email/purelymail.md` |
| Regular password | Cloudron, mailbox.org, GMX, IONOS, Namecheap, Hostinger, mail.com, Disroot, ChatMail, Zoho | |
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

## Hostinger Email

The domain registration and DNS **can remain at Cloudflare or any other registrar/DNS host**. Hostinger nameservers and domain transfer are optional conveniences (they only enable one-click automatic DNS setup), not requirements. An email plan does not need Hostinger web hosting; it is a separate service. Add the records below at the current DNS provider.

| Type | Host | Value |
|------|------|-------|
| TXT | per hPanel | Domain ownership proof (value shown in hPanel) |
| MX | `@` | `mx1.hostinger.com` priority 5; `mx2.hostinger.com` priority 10 |
| TXT | `@` | `v=spf1 include:_spf.mail.hostinger.com ~all` |
| CNAME | `hostingermail-a._domainkey` | `hostingermail-a.dkim.mail.hostinger.com` (same for `-b` and `-c`) |
| TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:dmarc@yourdomain.com` (start at `p=none`) |
| CNAME | `autodiscover` | `autodiscover.mail.hostinger.com` |
| CNAME | `autoconfig` | `autoconfig.mail.hostinger.com` |

- **Cloudflare**: set the CNAMEs to **DNS only** (grey cloud) and enter the short host name, because Cloudflare appends the zone. DKIM must be CNAME; publishing it as TXT breaks signing.
- **Verify**: hPanel > Emails > Mailboxes > Domain settings > **Check status**. Propagation can take 12-24 h.
- **Also sending via SES**: SPF needs both includes (see `services/email/ses.md`).
- **Client settings**: IMAP `imap.hostinger.com:993` TLS, SMTP `smtp.hostinger.com:465` TLS, POP3 `pop.hostinger.com:995` TLS (IMAP preferred). Username is the full address; use an app password when 2FA is on.
- **Pricing**: plans are prepaid, the headline price is a long-term (48-month) rate, and renewal is typically several times the intro price. Compare renewal price per mailbox, not intro price; check current renewal pricing. Contrast: Purelymail has a flat annual price with unlimited domains/users (`services/email/purelymail.md`).
- **Privacy**: rated C because the privacy policy describes marketing analysis and ad-platform targeting; it does not state that mailbox content is scanned. Operator: Hostinger International Ltd (Cyprus).

Sources: Hostinger Help Center "Set up a domain for Hostinger Email manually", docs.hostinger.com "Setting Up Apps & Devices". Hostinger verified 2026-11.

## Related

- `services/hosting/hostinger.md` — Hostinger hosting (email is a separate plan)
- `services/email/ses.md` — Amazon SES for outbound delivery
- `services/email/purelymail.md` — Purelymail mailbox hosting: DNS, users, routing, auth checks
- `services/email/email-agent.md` — Autonomous email agent
- `services/email/email-testing.md` — Deliverability testing
- `configs/email-providers.json.txt` — Provider configuration template

*Settings verified 2026-03. Privacy ratings from privacytools.io / tosdr.org. Verify against provider docs for production use.*
