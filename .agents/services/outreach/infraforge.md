---
description: Infraforge private email infrastructure playbook for domain, mailbox, DNS, and IP operations
mode: subagent
tools:
  read: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Infraforge

<!-- AI-CONTEXT-START -->

## Quick Reference

- Use Infraforge when outreach needs dedicated IP control, tighter isolation, and direct DNS/server ownership.
- Prefer Mailforge when speed-to-launch and lower operational burden matter more than infrastructure control.
- Use `.agents/scripts/infraforge-helper.sh` for all Infraforge API operations.
- Required environment: `INFRAFORGE_API_KEY`; add `INFRAFORGE_MAILBOX_PASSWORD` only for `mailboxes-create`.
- Core flow: `domains-provision` → `dns-upsert` → `mailboxes-create` → `ips-assign` → `ssl-enable` → domain masking when required.
- Before scaling, validate SPF/DKIM/DMARC, keep warmup conservative, and roll out DNS/IP changes in small batches.

## Infraforge vs Mailforge

| Dimension | Infraforge | Mailforge |
|---|---|---|
| Infrastructure model | Private/dedicated | Shared infrastructure |
| Deliverability control | High — you control dedicated IP and DNS posture | Medium — provider manages shared pool posture |
| Setup speed | Slower | Faster |
| Operational burden | Higher | Lower |
| Best fit | Long-term sender control | Faster launch with less ops overhead |

## Setup

Never paste secret values into AI chat. Set them in your terminal with hidden prompts.

```bash
aidevops secret set INFRAFORGE_API_KEY
export INFRAFORGE_API_KEY="<loaded-in-your-terminal-session>"
export INFRAFORGE_MAILBOX_PASSWORD="<mailbox-password>"
```

## Commands

- Domain provisioning: `domains/provision`
- DNS automation: `dns/upsert`
- Mailbox creation: `mailboxes/create`
- Dedicated IP assignment: `ips/assign`
- SSL enablement: `ssl/enable`
- Domain masking: `domain-masking/enable`

```bash
.agents/scripts/infraforge-helper.sh domains-provision sender-example.com
.agents/scripts/infraforge-helper.sh dns-upsert sender-example.com TXT @ "v=spf1 include:mail.example ~all" 3600
.agents/scripts/infraforge-helper.sh mailboxes-create sender-example.com inbox1
.agents/scripts/infraforge-helper.sh ips-list
.agents/scripts/infraforge-helper.sh ips-assign ip_123 sender-example.com
.agents/scripts/infraforge-helper.sh ssl-enable sender-example.com
```

## Operating Rules

1. Provision the sending domain.
2. Apply SPF/DKIM/DMARC, MX, and tracking-host DNS records.
3. Create mailboxes.
4. Assign a dedicated IP.
5. Enable SSL.
6. Enable domain masking when the sending architecture requires it.

- Keep mailbox throughput conservative during warmup; align with `services/outreach/cold-outreach.md`.
- Roll out DNS changes in small batches to reduce reputation shocks.
- Prefer one dedicated IP pool per campaign cohort for cleaner diagnostics.
- Validate SPF/DKIM/DMARC before scaling volume.

<!-- AI-CONTEXT-END -->
