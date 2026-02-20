---
description: Mobile app analytics - usage tracking, feedback loops, crash reporting, iteration signals
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

# App Analytics - Data-Driven Iteration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Track usage, gather feedback, monitor crashes, and drive iteration
- **Tools**: RevenueCat (revenue), Expo Analytics, PostHog (open-source), Sentry (crashes)
- **Principle**: Measure what matters for retention and revenue, not vanity metrics

**Shared with**: `browser-extension-dev.md` (same analytics principles)

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
| **RevenueCat** | Subscription analytics, cohort analysis | iOS + Android |
| **App Store Connect Analytics** | Downloads, impressions, conversion | iOS |
| **Google Play Console** | Install stats, ratings, crashes | Android |
| **Expo Analytics** | OTA update adoption, crash rates | Expo apps |
| **Firebase Analytics** | Event tracking, user properties | iOS + Android |

### Self-Hosting on Coolify

For privacy and cost control, self-host analytics on Coolify:

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

| Metric | What It Tells You |
|--------|-------------------|
| DAU/MAU ratio | How "sticky" the app is (> 20% is good) |
| Session length | How much time users spend |
| Sessions per day | How often users return |
| Core action completion | Whether users do the main thing |

### Revenue (if monetised)

| Metric | What It Tells You |
|--------|-------------------|
| Trial-to-paid conversion | Paywall effectiveness |
| Monthly recurring revenue (MRR) | Business health |
| Average revenue per user (ARPU) | Monetisation efficiency |
| Churn rate | How fast you lose subscribers |
| Lifetime value (LTV) | Long-term user value |

RevenueCat provides most revenue metrics out of the box.

### Quality

| Metric | Target | Tool |
|--------|--------|------|
| Crash-free rate | > 99.5% | Sentry |
| App launch time | < 2 seconds | Performance monitoring |
| API error rate | < 1% | Sentry / custom |
| App Store rating | > 4.5 stars | App Store Connect |

## User Feedback Loops

### In-App Feedback

- **Rating prompt**: After positive experience (completed streak, achieved goal), not randomly
- **Feedback form**: Accessible from settings, low friction
- **Feature requests**: Simple upvote system or feedback board
- **Bug reports**: Shake-to-report with automatic context (device, OS, screen)

### App Store Reviews

- Monitor reviews daily (automate with App Store Connect API)
- Respond to negative reviews with solutions
- Track common themes in feedback
- Use review insights to prioritise features

### Analytics-Driven Iteration

```text
1. Identify metric below target
2. Hypothesise cause (e.g., "users drop off at step 3 of onboarding")
3. Design experiment (A/B test or feature change)
4. Implement and measure
5. Keep winner, iterate on losers
```

## Implementation

### Event Tracking Best Practices

- Track actions, not screens (what users DO, not where they GO)
- Use consistent naming: `verb_noun` (e.g., `complete_onboarding`, `start_workout`, `purchase_premium`)
- Include relevant properties (duration, count, category)
- Don't over-track — focus on events that inform decisions

### Privacy Compliance

- Respect App Tracking Transparency (iOS)
- Provide opt-out for analytics
- Don't collect PII unless necessary
- Comply with GDPR/CCPA if applicable
- Use privacy-friendly tools (PostHog, Plausible) when possible

## Related

- `mobile-app-dev/monetisation.md` - Revenue analytics via RevenueCat
- `mobile-app-dev/onboarding.md` - Onboarding funnel optimisation
- `tools/deployment/coolify.md` - Self-hosting analytics
- `services/analytics/google-analytics.md` - Web analytics (if app has web component)
