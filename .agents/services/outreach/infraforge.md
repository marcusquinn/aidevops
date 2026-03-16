---
description: Infraforge private email infrastructure playbook for domain, mailbox, DNS, and IP operations
mode: subagent
tools:
  read: true
  bash: true
---

# Infraforge

Infraforge is the private-infrastructure option for outreach sending. Use it when you need dedicated IP control, tighter isolation, and deeper DNS/server ownership than shared mailbox providers.

## Infraforge vs Mailforge

| Dimension | Infraforge | Mailforge |
|---|---|---|
| Infrastructure model | Private/dedicated | Shared infrastructure |
| Deliverability control | High (dedicated IP and DNS posture control) | Medium (provider-managed shared pool posture) |
| Setup speed | Slower (more provisioning steps) | Faster (lower setup overhead) |
| Operational burden | Higher (you own more moving parts) | Lower (provider abstracts infrastructure operations) |
| Best fit | Teams optimizing long-term sender control | Teams optimizing speed-to-launch |

## What This Covers

- Domain provisioning (`domains/provision`)
- Mailbox creation (`mailboxes/create`)
- DNS automation (`dns/upsert`)
- Dedicated IP assignment (`ips/assign`)
- SSL enablement (`ssl/enable`)
- Domain masking (`domain-masking/enable`)

## Helper Script

Use `.agents/scripts/infraforge-helper.sh` for API operations.

### Required Environment

- `INFRAFORGE_API_KEY`
- `INFRAFORGE_MAILBOX_PASSWORD` (only for mailbox creation)

WARNING: Never paste secret values into AI chat. Run secret setup commands in your terminal and enter values at hidden prompts.

Suggested setup:

```bash
aidevops secret set INFRAFORGE_API_KEY
export INFRAFORGE_API_KEY="<loaded-in-your-terminal-session>"
export INFRAFORGE_MAILBOX_PASSWORD="<mailbox-password>"
```

## Typical Provisioning Flow

1. Provision sending domain
2. Apply DNS records (SPF/DKIM/DMARC, MX, tracking host)
3. Create mailbox(es)
4. Assign dedicated IP to the sending domain
5. Enable SSL
6. Enable domain masking if required by your sending architecture

## Example Commands

```bash
.agents/scripts/infraforge-helper.sh domains-provision sender-example.com
.agents/scripts/infraforge-helper.sh dns-upsert sender-example.com TXT @ "v=spf1 include:mail.example ~all" 3600
.agents/scripts/infraforge-helper.sh mailboxes-create sender-example.com inbox1
.agents/scripts/infraforge-helper.sh ips-list
.agents/scripts/infraforge-helper.sh ips-assign ip_123 sender-example.com
.agents/scripts/infraforge-helper.sh ssl-enable sender-example.com
```

## Operational Notes

- Keep mailbox throughput conservative during warmup (align with `services/outreach/cold-outreach.md` guidance)
- Roll out DNS changes in small batches to reduce reputation shocks
- Use one dedicated IP pool per campaign cohort when possible for cleaner diagnostics
- Validate SPF/DKIM/DMARC before scaling volume
