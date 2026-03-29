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

### Open-Source Preferred

| Tool | Purpose | Self-Hosted | Cloud |
|------|---------|-------------|-------|
| **PostHog** | Product analytics, feature flags, session replay | Yes (Coolify) | Free tier |
| **Sentry** | Crash reporting, error tracking, performance | Yes (Coolify) | Free tier |
| **Plausible** | Privacy-friendly web analytics | Yes (Coolify) | Paid |
| **Umami** | Simple web analytics | Yes (Coolify) | Free |

### Platform-Specific

| Tool | Purpose | Platform |
|------|---------|----------|
| **RevenueCat** | Subscription analytics, cohort analysis | Mobile (iOS + Android) |
| **App Store Connect Analytics** | Downloads, impressions, conversion | iOS |
| **Google Play Console** | Install stats, ratings, crashes | Android |
| **Chrome Web Store Dashboard** | Installs, uninstalls, ratings | Chrome extensions |
| **Firefox Add-on Statistics** | Downloads, daily users | Firefox extensions |
| **Expo Analytics** | OTA update adoption, crash rates | Expo apps |
| **Firebase Analytics** | Event tracking, user properties | Mobile + web |

### Self-Hosting on Coolify

```text
PostHog -> Coolify one-click deploy -> your-analytics.yourdomain.com
Sentry  -> Coolify one-click deploy -> your-sentry.yourdomain.com
```

See `tools/deployment/coolify.md` for deployment guidance.

## Key Metrics

### Retention (Most Important)

| Metric | Target | Action if Below |
|--------|--------|-----------------|
| Day 1 retention | > 40% | Fix onboarding |
| Day 7 retention | > 20% | Improve core loop |
| Day 30 retention | > 10% | Add engagement features |

### Engagement

| Metric | Signal |
|--------|--------|
| DAU/MAU ratio | Stickiness (> 20% is good) |
| Session length | Time spent |
| Sessions per day | Return frequency |
| Core action completion | Users doing the main thing |

### Revenue (if monetised)

| Metric | Signal |
|--------|--------|
| Trial-to-paid conversion | Paywall effectiveness |
| MRR | Business health |
| ARPU | Monetisation efficiency |
| Churn rate | Subscriber loss rate |
| LTV | Long-term user value |

RevenueCat provides most revenue metrics out of the box for mobile. For web/desktop, use Stripe dashboard or custom analytics.

### Quality

| Metric | Target | Tool |
|--------|--------|------|
| Crash-free rate | > 99.5% | Sentry |
| Launch/load time | < 2s | Performance monitoring |
| API error rate | < 1% | Sentry / custom |
| Store rating | > 4.5 stars | Store dashboards |

## User Feedback Loops

### In-Product

- **Rating prompt**: After positive experience (completed streak, achieved goal) — not randomly
- **Feedback form**: Low-friction, accessible from settings
- **Feature requests**: Upvote system or feedback board
- **Bug reports**: Easy reporting with automatic context (device, OS, screen)

### Store Reviews

- Monitor daily (automate with store APIs where available)
- Respond to negative reviews with solutions
- Track common themes to prioritise features

### Analytics-Driven Iteration

```text
1. Identify metric below target
2. Hypothesise cause (e.g., "users drop off at step 3 of onboarding")
3. Design experiment (A/B test or feature change)
4. Implement and measure
5. Keep winner, iterate on losers
```

## Implementation

### Event Tracking

- Track actions, not screens (what users DO, not where they GO)
- Naming: `verb_noun` (e.g., `complete_onboarding`, `start_workout`, `purchase_premium`)
- Include relevant properties (duration, count, category)
- Don't over-track — focus on events that inform decisions

### Privacy Compliance

- Respect App Tracking Transparency (iOS)
- Provide analytics opt-out
- Avoid PII collection unless necessary
- GDPR/CCPA compliance when applicable
- Prefer privacy-friendly tools (PostHog, Plausible)

## Related

- `product/monetisation.md` - Revenue analytics
- `product/onboarding.md` - Onboarding funnel optimisation
- `product/growth.md` - Acquisition metrics and channel attribution
- `tools/deployment/coolify.md` - Self-hosting analytics
- `services/analytics/google-analytics.md` - Web analytics (GA4)
- `services/monitoring/sentry.md` - Error monitoring
