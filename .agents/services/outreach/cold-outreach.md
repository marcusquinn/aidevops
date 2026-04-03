---
description: Cold outreach strategy playbook - warmup, compliance, infrastructure, and platform selection
mode: subagent
tools:
  read: true
---

# Cold Outreach Strategy

## Quick Reference

- Dedicated sending domains/inboxes — never cold-send from primary business domain
- Ramp each mailbox 5→20 emails/day over 4 weeks before production volume
- Hard cap: 100 emails/day per mailbox (first touch + follow-ups + replies)
- Rotate volume across warmed mailboxes; never push one above safe limits
- CAN-SPAM and GDPR controls by default (physical address, one-click unsubscribe, legitimate-interest docs)
- Auto-detect positive replies → hand off to human-managed conversation flows

## Compliance Baseline

| Regulation | Requirements |
|---|---|
| CAN-SPAM (US) | Non-deceptive sender/subject; valid postal address; one-click unsubscribe (RFC 8058); honor opt-outs promptly |
| GDPR Legitimate Interest (EU/UK) | Document balancing test; minimize personal data; objection/deletion pathways in first contact and footer; maintain processing records and suppression logs |

## Warmup and Volume

| Week | Daily Target | Notes |
|------|---:|---|
| 1 | 5-8 | Warmup network traffic + light manual sends |
| 2 | 9-12 | Add low-risk prospects; monitor bounces/spam placement |
| 3 | 13-16 | Increase follow-ups; keep copy variation high |
| 4 | 17-20 | Stable warm baseline; reply handling human-in-loop |

Scale above 20/day only after 7+ days of stable inbox health. Plan: `target_daily_volume / 100 = minimum active mailboxes`. Add 20-30% headroom for pauses and deliverability degradation.

**Multi-mailbox rotation:** Group by reputation tier (new, warming, stable); route high-priority accounts through stable first. Distribute sequence steps evenly — no mailbox peaks at one hour/daypart. Pause on anomaly signals (bounce spike, spam-folder drift, complaints); rebalance to healthy mailboxes.

## Platform Selection

| Platform | Strengths | Trade-Offs | Best Fit |
|---|---|---|---|
| Smartlead | Mature inbox rotation, unified inbox, strong deliverability, API-friendly | Higher complexity for small teams | Multi-mailbox outbound at scale |
| Instantly | Fast onboarding, broad community playbooks, integrated lead/campaign workflows | Avoid over-automation without QA | Speed-to-launch and experimentation |
| ManyReach | Lean interface, simple ops, cost-conscious | Smaller ecosystem, fewer orchestration features | Lightweight outbound with lower overhead |

**Infrastructure:**

| Option | Model | Use When |
|---|---|---|
| Infraforge | Private/dedicated | Tighter infrastructure control needed |
| Mailforge | Shared | Speed and lower complexity for standard outbound |
| Primeforge | Google Workspace / M365 | Enterprise mailbox stack alignment |
| FluentCRM | WordPress-native | Outreach tightly coupled to WordPress funnels and owned contact data; sync list governance to avoid re-contacting unsubscribed leads |

## Messaging Quality

- No mass-templated openings ("just circling back," "quick question," "hope this finds you well")
- Use context-grounded observations tied to recipient's role, timing, or initiative
- Trigger from verifiable business signals (hiring, launch, stack changes, expansion)
- One problem hypothesis + one clear CTA per email; one relevant case/metric per prospect segment
- Vary openings and CTAs to reduce template fingerprinting

## Reply Detection and Handoff

1. Classify replies: positive, neutral, objection, unsubscribe
2. Auto-stop sequences on any reply or suppression event
3. Route positive/high-intent neutral replies to human owner with SLA
4. Track handoff latency and outcome in CRM for loop closure
5. Feed objection patterns back into copy and segmentation weekly
