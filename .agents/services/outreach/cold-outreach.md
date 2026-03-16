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

- Use dedicated sending domains and inboxes for outreach; never send cold campaigns from the primary business domain
- Ramp each new mailbox from 5 emails/day to 20 emails/day over 4 weeks before scaling to production volume
- Hard cap mailbox throughput at 100 emails/day total (new sends + follow-ups + manual replies)
- Rotate volume across multiple warmed mailboxes instead of pushing one mailbox above safe limits
- Maintain CAN-SPAM and GDPR controls by default (physical address, one-click unsubscribe, legitimate-interest documentation)
- Prioritize positive-reply handoff: automate detection, then move qualified responses into human-managed conversation flows

### Default Warmup Ramp (Per Mailbox)

| Week | Daily Send Target | Notes |
|---|---:|---|
| 1 | 5-8/day | Mostly warmup network traffic and light manual sends |
| 2 | 9-12/day | Add low-risk prospects, monitor bounces and spam placement |
| 3 | 13-16/day | Increase follow-ups slowly; keep copy variation high |
| 4 | 17-20/day | Stable warm baseline; keep reply handling human-in-loop |

Scale above 20/day only after inbox health remains stable for at least 7 days (low bounce, low complaint, stable inbox placement).

### Daily Limits and Volume Math

- Treat `100/day` as a hard technical and reputation limit per mailbox
- Include all outbound activity in that number: first touch, follow-up sequence steps, and one-off replies
- Plan outreach in aggregate: `target_daily_volume / 100 = minimum active mailboxes`
- Add 20-30% mailbox headroom for pauses, warmup replacement, and deliverability degradation

### Multi-Mailbox Rotation Pattern

1. Group mailboxes by sending domain and reputation tier (new, warming, stable)
2. Route high-priority accounts through stable mailboxes first
3. Evenly distribute sequence steps so no mailbox peaks at one hour/daypart
4. Pause individual mailboxes on anomaly signals (bounce spike, spam-folder drift, complaint events)
5. Rebalance to remaining healthy mailboxes while remediation runs

### Compliance Baseline

#### CAN-SPAM (US)

- Use non-deceptive sender identity and subject lines
- Include valid postal address in each campaign email
- Provide a one-click unsubscribe mechanism (RFC 8058 where supported)
- Honor opt-out requests quickly and suppress future sends automatically

#### GDPR Legitimate Interest (EU/UK)

- Record legal basis as legitimate interest for B2B prospecting where applicable
- Document balancing test outcomes (business need vs contact privacy impact)
- Minimize personal data fields to outreach-essential attributes only
- Provide clear objection and deletion pathways in the first contact and footer
- Maintain processing records and suppression logs for auditability

### Platform Comparison (Cold Outreach)

| Platform | Strengths | Trade-Offs | Best Fit |
|---|---|---|---|
| Smartlead | Mature inbox rotation, unified inbox, strong deliverability controls, API-friendly for automation | Higher complexity for small teams, setup discipline required | Teams running multi-mailbox outbound at scale with automation needs |
| Instantly | Fast onboarding, broad community playbooks, integrated lead and campaign workflows | Feature depth can vary by workflow; avoid over-automation without QA | Teams optimizing speed-to-launch and broad campaign experimentation |
| ManyReach | Leaner interface, simpler operational footprint, cost-conscious entry point | Smaller ecosystem and fewer advanced orchestration capabilities | Smaller teams that need lightweight outbound ops with lower overhead |

### Infrastructure Decision Framework

| Option | Model | Pros | Cons | Use When |
|---|---|---|---|---|
| Infraforge | Private/dedicated infrastructure | More control over sender environment and isolation | Higher setup and management burden | You need tighter infrastructure control and can operate dedicated environments |
| Mailforge | Shared infrastructure | Faster setup and lower ops overhead | Less isolation/control than private deployments | You need speed and lower complexity for standard outbound programs |
| Primeforge | Google Workspace / Microsoft 365 based | Uses mainstream mailbox ecosystems and familiar admin workflows | Policy constraints and cost profile depend on provider tenancy | You need enterprise mailbox stack alignment with Google/MS365 workflows |

### FluentCRM as a WordPress-Centric Alternative

- Use FluentCRM when outreach is tightly coupled to WordPress-hosted funnels, forms, and owned contact data
- Prefer FluentCRM for consent-aware lifecycle messaging; use dedicated outbound platforms for cold scale
- Keep list governance synchronized between FluentCRM and outbound tools to avoid re-contacting unsubscribed leads

### Messaging Quality Controls

#### Avoid Overused Cold Email Phrases

Avoid openings that look mass-templated (for example: "just circling back," "quick question," "hope this finds you well"). Replace with context-grounded, specific observations tied to the recipient's role, timing, or initiative.

#### B2B Personalization Patterns

- Trigger personalization from verifiable business signals (hiring, launch, stack changes, regional expansion)
- Anchor each email to one problem hypothesis and one clear call-to-action
- Keep proof concise: one relevant case, metric, or example that matches the prospect segment
- Maintain variation across openings and CTAs to reduce template fingerprinting

### Reply Detection and Handoff

1. Classify replies into positive, neutral, objection, and unsubscribe
2. Auto-stop sequences immediately for any reply and suppression event
3. Route positive and high-intent neutral replies to a human owner with SLA
4. Track handoff latency and outcome in CRM for loop closure
5. Feed objection patterns back into copy and segmentation updates weekly

<!-- AI-CONTEXT-END -->

Use this document as the baseline policy for cold outreach strategy tasks. For execution workflows, pair it with campaign tooling docs and CRM-specific operating procedures.
