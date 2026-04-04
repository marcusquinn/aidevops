<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1492: Email provider config templates and privacy ratings

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 1 foundation — no dependencies)
- **Conversation context:** Comprehensive email system planning session identified need for provider-agnostic configuration layer supporting 15+ email providers with IMAP/SMTP/JMAP settings and privacy ratings.

## What

Create `configs/email-providers.json.txt` template and `services/email/email-providers.md` agent doc containing:

1. IMAP/SMTP/JMAP connection settings for all major providers: Cloudron, Gmail, Google Workspace, Outlook/365, Hotmail, Yahoo, ProtonMail, Fastmail, mailbox.org, Tutanota, Namecheap, mail.com, Zoho Mail, GMX, IONOS, StartMail, Disroot, ChatMail
2. Privacy ratings per provider (sourced from privacytools.io data): E2E support, jurisdiction, open-source status, data mining policies
3. Protocol support matrix: which providers support IMAP, JMAP, Graph API, POP
4. Default folder name mappings (Gmail labels vs IMAP folders vs Outlook categories)
5. POP vs IMAP decision guidance (POP for shared mailboxes where all users read same emails, IMAP generally preferred)
6. Shared mailbox patterns: common addresses (info@, support@, sales@, enquiries@, accounts@, marketing@, admin@, webmaster@, buyers@, dataprotection@, legal@)
7. Cloudron mailbox management via CLI notes

## Why

Every subsequent email helper needs to know how to connect to a provider. Without a central provider config, each helper reinvents connection logic. Privacy ratings inform which providers to recommend for sensitive communications. Folder name differences across providers cause silent failures if not mapped.

## How (Approach)

- Create `configs/email-providers.json.txt` with provider entries keyed by slug
- Create `services/email/email-providers.md` agent doc following existing pattern (see `services/email/ses.md` for structure)
- Reference privacytools.io privacy ratings (already fetched in planning session)
- Follow existing config template pattern: `.json.txt` committed, `.json` gitignored

## Acceptance Criteria

- [ ] `configs/email-providers.json.txt` exists with 15+ provider entries
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/configs/email-providers.json.txt && jq '.providers | length >= 15' .agents/configs/email-providers.json.txt"
  ```
- [ ] Each provider entry has: slug, name, imap_host, imap_port, smtp_host, smtp_port, jmap_url (if supported), protocol_support array, privacy_rating, jurisdiction, default_folders mapping
- [ ] `services/email/email-providers.md` exists with AI-CONTEXT-START/END markers
  ```yaml
  verify:
    method: codebase
    pattern: "AI-CONTEXT-START"
    path: ".agents/services/email/email-providers.md"
  ```
- [ ] Shared mailbox patterns documented with common address list
- [ ] POP vs IMAP decision tree included
- [ ] ShellCheck clean (no scripts in this task, but lint any examples)

## Context & Decisions

- Privacy ratings sourced from privacytools.io: ProtonMail, Tutanota, StartMail, mailbox.org, Disroot rated highest
- JMAP support is limited to Fastmail (reference implementation) and a few others — most providers are IMAP-only
- Gmail uses labels not folders — requires special mapping logic
- Outlook/365 shared mailboxes use Graph API, not standard IMAP

## Relevant Files

- `.agents/configs/ses-config.json.txt` — existing config template pattern to follow
- `.agents/services/email/ses.md` — existing email service agent doc pattern
- `.agents/services/communications/slack.md` — comprehensive service doc example

## Dependencies

- **Blocked by:** none
- **Blocks:** t1493 (mailbox helper needs provider configs), t1494 (Apple Mail needs provider awareness)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Verify provider settings, check JMAP support |
| Implementation | 2h | Config template + agent doc |
| Testing | 30m | Validate JSON structure, verify provider settings |
| **Total** | **3h** | |
