---
description: Infraforge private email infrastructure playbook for domain, mailbox, DNS, and IP operations
mode: subagent
tools:
  read: true
  bash: true
---

# Infraforge

Infraforge is the private-infrastructure option for outreach sending. Use it when you need dedicated IP control, tighter isolation, and direct DNS/server ownership.

## Infraforge vs Mailforge

| Dimension | Infraforge | Mailforge |
|---|---|---|
| Infrastructure model | Private/dedicated | Shared infrastructure |
| Deliverability control | High (dedicated IP and DNS posture control) | Medium (provider-managed shared pool posture) |
| Setup speed | Slower (more provisioning steps) | Faster (lower setup overhead) |
| Operational burden | Higher (you own more moving parts) | Lower (provider abstracts infrastructure operations) |
| Best fit | Teams optimizing long-term sender control | Teams optimizing speed-to-launch |

## API Surfaces

- Domain provisioning (`domains/provision`)
- DNS automation (`dns/upsert`)
- Mailbox creation (`mailboxes/create`)
- Dedicated IP assignment (`ips/assign`)
- SSL enablement (`ssl/enable`)
- Domain masking (`domain-masking/enable`)

## Helper Script

Use `.agents/scripts/infraforge-helper.sh` for all Infraforge API operations.

### Required Environment

- `INFRAFORGE_API_KEY`
- `INFRAFORGE_MAILBOX_PASSWORD` (only for mailbox creation)

Never paste secret values into AI chat. Set secrets in your terminal with hidden prompts.

Suggested setup:

```bash
aidevops secret set INFRAFORGE_API_KEY
export INFRAFORGE_API_KEY="<loaded-in-your-terminal-session>"
export INFRAFORGE_MAILBOX_PASSWORD="<mailbox-password>"
```

## Provisioning Flow

1. Provision sending domain (`domains-provision`)
2. Apply DNS records (`dns-upsert` for SPF/DKIM/DMARC, MX, tracking host)
3. Create mailboxes (`mailboxes-create`)
4. Assign dedicated IP (`ips-assign`)
5. Enable SSL (`ssl-enable`)
6. Enable domain masking when required by your sending architecture

## Command Examples

```bash
.agents/scripts/infraforge-helper.sh domains-provision sender-example.com
.agents/scripts/infraforge-helper.sh dns-upsert sender-example.com TXT @ "v=spf1 include:mail.example ~all" 3600
.agents/scripts/infraforge-helper.sh mailboxes-create sender-example.com inbox1
.agents/scripts/infraforge-helper.sh ips-list
.agents/scripts/infraforge-helper.sh ips-assign ip_123 sender-example.com
.agents/scripts/infraforge-helper.sh ssl-enable sender-example.com
```

## Operational Guardrails

- Keep mailbox throughput conservative during warmup (align with `services/outreach/cold-outreach.md` guidance)
- Roll out DNS changes in small batches to reduce reputation shocks
- Use one dedicated IP pool per campaign cohort when possible for cleaner diagnostics
- Validate SPF/DKIM/DMARC before scaling volume
