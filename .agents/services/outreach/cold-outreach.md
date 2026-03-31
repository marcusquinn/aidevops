---
description: Cold outreach strategy playbook - warmup, compliance, infrastructure, and platform selection
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

# Cold Outreach Strategy

<!-- AI-CONTEXT-START -->

## Quick Reference

- Dedicated sending domains/inboxes for outreach — never cold-send from primary business domain
- Ramp each new mailbox 5→20 emails/day over 4 weeks before production volume
- Hard cap: 100 emails/day per mailbox (new sends + follow-ups + replies)
- Rotate volume across multiple warmed mailboxes; never push one above safe limits
- CAN-SPAM and GDPR controls by default (physical address, one-click unsubscribe, legitimate-interest docs)
- Auto-detect positive replies → hand off to human-managed conversation flows

## Compliance Baseline

### CAN-SPAM (US)

- Non-deceptive sender identity and subject lines
- Valid postal address in each campaign email
- One-click unsubscribe (RFC 8058 where supported)
- Honor opt-outs promptly; auto-suppress future sends

### GDPR Legitimate Interest (EU/UK)

- Legal basis: legitimate interest for B2B prospecting where applicable
- Document balancing test outcomes (business need vs privacy impact)
- Minimize personal data to outreach-essential attributes
- Clear objection/deletion pathways in first contact and footer
- Maintain processing records and suppression logs

## Warmup and Volume

### Default Warmup Ramp (Per Mailbox)

| Week | Daily Target | Notes |
|------|---:|---|
| 1 | 5-8 | Warmup network traffic + light manual sends |
| 2 | 9-12 | Add low-risk prospects; monitor bounces/spam placement |
| 3 | 13-16 | Increase follow-ups; keep copy variation high |
| 4 | 17-20 | Stable warm baseline; reply handling human-in-loop |

Scale above 20/day only after 7+ days of stable inbox health (low bounce, low complaint, stable placement).

### Daily Limits

- `100/day` hard cap per mailbox — includes first touch, follow-up steps, and one-off replies
- Plan: `target_daily_volume / 100 = minimum active mailboxes`
- Add 20-30% mailbox headroom for pauses, warmup replacement, deliverability degradation

### Multi-Mailbox Rotation

1. Group mailboxes by sending domain and reputation tier (new, warming, stable)
2. Route high-priority accounts through stable mailboxes first
3. Distribute sequence steps evenly — no mailbox peaks at one hour/daypart
4. Pause individual mailboxes on anomaly signals (bounce spike, spam-folder drift, complaints)
5. Rebalance to remaining healthy mailboxes during remediation

## Platform Selection

### Cold Outreach Platforms

| Platform | Strengths | Trade-Offs | Best Fit |
|---|---|---|---|
| Smartlead | Mature inbox rotation, unified inbox, strong deliverability, API-friendly | Higher complexity for small teams | Multi-mailbox outbound at scale with automation |
| Instantly | Fast onboarding, broad community playbooks, integrated lead/campaign workflows | Feature depth varies by workflow; avoid over-automation without QA | Speed-to-launch and broad campaign experimentation |
| ManyReach | Lean interface, simple ops, cost-conscious entry | Smaller ecosystem, fewer advanced orchestration features | Lightweight outbound with lower overhead |

### Infrastructure Options

| Option | Model | Pros | Cons | Use When |
|---|---|---|---|---|
| Infraforge | Private/dedicated | More control, sender isolation | Higher setup/management burden | Tighter infrastructure control needed |
| Mailforge | Shared | Faster setup, lower ops overhead | Less isolation/control | Speed and lower complexity for standard outbound |
| Primeforge | Google Workspace / M365 | Mainstream mailbox ecosystems, familiar admin | Policy constraints, cost depends on tenancy | Enterprise mailbox stack alignment |

### FluentCRM (WordPress-Centric)

- Use when outreach is tightly coupled to WordPress-hosted funnels, forms, and owned contact data
- Prefer for consent-aware lifecycle messaging; use dedicated outbound platforms for cold scale
- Sync list governance between FluentCRM and outbound tools to avoid re-contacting unsubscribed leads

## Messaging Quality

### Avoid Overused Phrases

Avoid mass-templated openings ("just circling back," "quick question," "hope this finds you well"). Replace with context-grounded observations tied to recipient's role, timing, or initiative.

### B2B Personalization

- Trigger from verifiable business signals (hiring, launch, stack changes, regional expansion)
- One problem hypothesis + one clear CTA per email
- One relevant case/metric/example matching the prospect segment
- Vary openings and CTAs to reduce template fingerprinting

## Reply Detection and Handoff

1. Classify replies: positive, neutral, objection, unsubscribe
2. Auto-stop sequences on any reply or suppression event
3. Route positive/high-intent neutral replies to human owner with SLA
4. Track handoff latency and outcome in CRM for loop closure
5. Feed objection patterns back into copy and segmentation weekly

<!-- AI-CONTEXT-END -->

Use this document as the baseline policy for cold outreach strategy tasks. Pair with campaign tooling docs and CRM-specific operating procedures for execution workflows.
