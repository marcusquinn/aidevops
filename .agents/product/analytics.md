---
description: Product analytics - usage tracking, feedback loops, crash reporting, iteration signals for any app type
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Product Analytics - Data-Driven Iteration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Track usage, gather feedback, monitor crashes, drive iteration
- **Tools**: PostHog (open-source), Sentry (crashes), RevenueCat (mobile revenue), Plausible (web)
- **Principle**: Measure retention and revenue, not vanity metrics
- **Applies to**: Mobile, browser extensions, desktop, web apps

<!-- AI-CONTEXT-END -->

## Analytics Stack

Open-source preferred. All self-hostable on Coolify — see `tools/deployment/coolify.md`.

| Tool | Purpose | Notes |
|------|---------|-------|
| **PostHog** | Product analytics, feature flags, session replay | Self-hosted or free cloud tier |
| **Sentry** | Crash reporting, error tracking, performance | Self-hosted or free cloud tier |
| **Plausible** | Privacy-friendly web analytics | Self-hosted or paid cloud |
| **Umami** | Simple web analytics | Self-hosted or free cloud |
| **RevenueCat** | Subscription analytics, cohort analysis | Mobile (iOS + Android) |
| **Firebase Analytics** | Event tracking, user properties | Mobile + web |
| **Expo Analytics** | OTA update adoption, crash rates | Expo apps |

Platform dashboards: App Store Connect (iOS), Google Play Console (Android), Chrome Web Store, Firefox Add-on Statistics.

## Key Metrics

### Retention (most important)

| Metric | Target | Action if below |
|--------|--------|-----------------|
| Day 1 | > 40% | Fix onboarding |
| Day 7 | > 20% | Improve core loop |
| Day 30 | > 10% | Add engagement features |

### Engagement

| Metric | Signal |
|--------|--------|
| DAU/MAU ratio | Stickiness (> 20% good) |
| Session length / sessions per day | Time spent, return frequency |
| Core action completion | Users doing the main thing |

### Revenue (if monetised)

| Metric | Signal |
|--------|--------|
| Trial-to-paid conversion | Paywall effectiveness |
| MRR / ARPU | Business health, monetisation efficiency |
| Churn rate / LTV | Subscriber loss, long-term value |

RevenueCat provides most revenue metrics out of the box for mobile. For web/desktop, use Stripe dashboard or custom analytics.

### Quality

| Metric | Target | Tool |
|--------|--------|------|
| Crash-free rate | > 99.5% | Sentry |
| Launch/load time | < 2s | Performance monitoring |
| API error rate | < 1% | Sentry / custom |
| Store rating | > 4.5 stars | Store dashboards |

## User Feedback Loops

**In-product**: Rating prompt after positive experience (not randomly). Low-friction feedback form in settings. Feature request upvote system. Bug reports with automatic context (device, OS, screen).

**Store reviews**: Monitor daily (automate with store APIs). Respond to negative reviews with solutions. Track common themes to prioritise features.

### Analytics-Driven Iteration

```text
1. Identify metric below target
2. Hypothesise cause (e.g., "users drop off at step 3 of onboarding")
3. Design experiment (A/B test or feature change)
4. Implement and measure
5. Keep winner, iterate on losers
```

## Implementation

**Event tracking**: Track actions, not screens (what users DO, not where they GO). Naming: `verb_noun` (e.g., `complete_onboarding`, `start_workout`, `purchase_premium`). Include relevant properties (duration, count, category). Don't over-track — focus on events that inform decisions.

**Privacy compliance**: Respect App Tracking Transparency (iOS). Provide analytics opt-out. Avoid PII unless necessary. GDPR/CCPA compliance when applicable. Prefer privacy-friendly tools (PostHog, Plausible).

## Related

- `product/monetisation.md` - Revenue analytics
- `product/onboarding.md` - Onboarding funnel optimisation
- `product/growth.md` - Acquisition metrics and channel attribution
- `tools/deployment/coolify.md` - Self-hosting analytics
- `services/analytics/google-analytics.md` - Web analytics (GA4)
- `services/monitoring/sentry.md` - Error monitoring
