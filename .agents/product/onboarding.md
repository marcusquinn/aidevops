---
description: Product onboarding flows - first-run experience, progressive disclosure, paywall placement for any app type
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Product Onboarding - First Impressions That Convert

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Get users to value quickly — every screen must earn its place
- **Research**: Study top products on Mobbin (https://mobbin.com/) for proven patterns
- **Max screens**: 3-5 (fewer is better)
- **Applies to**: Mobile apps, browser extensions, desktop apps, web apps

<!-- AI-CONTEXT-END -->

## Design Principles

**Every screen must earn its place** — only add if the user needs it now, it can't be deferred, and it increases retention.

**Skip always visible** (except hard paywall): "Skip" button, progress indicator, back navigation.

**Permissions**: Request in context, not upfront. Exception: core-function permissions (e.g., camera app) — request during onboarding with explanation.

| Permission | When to Ask |
|------------|-------------|
| Notifications | After first action |
| Location | When user opens map/location feature |
| Camera | When user taps camera button |
| Health data | When user enables health tracking |
| Browser permissions | When user triggers the feature needing it |

**Account creation** — defer unless required for core functionality:

| Level | When |
|-------|------|
| No account | Local-only products, utilities, tools |
| Optional | Sync across devices, social features |
| Required | Multi-user, cloud-based, subscription products |

When required: Sign in with Apple (mandatory on iOS if any third-party sign-in exists) → Google → Email + password.

**Paywall placement** — see `product/monetisation.md`. Mirror competitors if hard paywalls work in the niche; otherwise show after first core action.

| Position | Pros | Cons |
|----------|------|------|
| After onboarding, before product (hard) | High visibility, max revenue/install | User hasn't experienced value |
| After first core action (soft) | User has experienced value | Lower visibility |
| After 3 days of use (delayed) | Highest conversion | Delayed revenue |

**Animation**: Invest in smooth transitions, subtle animations (Lottie, Remotion), haptic feedback (mobile), intentional loading states. See `product/ui-design.md`.

## Onboarding Patterns

### Pattern 1: Value-First (Recommended)

```text
1. Welcome (brand + one-line value prop)
2. Core experience preview (show what the product does)
3. Quick setup (name, preferences — minimal)
4. Permission requests (only what's needed now)
5. Ready screen (clear CTA to start using)
```

### Pattern 2: Progressive Setup

```text
1. Welcome
2. "What's your goal?" (personalisation question)
3. "How often?" (frequency/commitment)
4. Personalised preview (show tailored experience)
5. Account creation (optional, defer if possible)
```

### Pattern 3: Feature Tour

```text
1. Welcome
2. Feature 1 demo (interactive, not just text)
3. Feature 2 demo
4. "You're ready" (summary of what they can do)
```

### Pattern 4: Hard Paywall (High-revenue B2C)

```text
1. Welcome (brand + bold value prop)
2. "What's your goal?" (personalisation — builds investment)
3. Problem reminder (why they downloaded/installed)
4. Solution preview (how the product solves it)
5. Social proof (user count, testimonials, ratings)
6. Hard paywall (unskippable — pay or start free trial)
```

Use when B2C competitors use hard paywalls. Validate against top-grossing competitors. Weak onboarding + hard paywall = churn. Strong onboarding + hard paywall = max revenue. A/B test once you have traffic.

| Aspect | Hard Paywall | Soft Paywall (feature-gated) |
|--------|-------------|------------------------------|
| Revenue per install | Higher | Lower |
| Conversion rate | Lower (many bounce) | Higher (more try first) |
| User quality | Higher (committed) | Mixed |
| App Store ratings | Risk of negative reviews | Generally better |
| Best for | Proven niches, validated demand | New/unvalidated products |

## Metrics

| Metric | Target |
|--------|--------|
| Completion rate | > 80% |
| Time to complete | < 60s |
| Day 1 retention | > 40% |
| Day 7 retention | > 20% |
| Permission grant rate | > 60% |

## Platform Notes

| Platform | Key considerations |
|----------|--------------------|
| Mobile | Full-screen swipeable; haptic feedback; show onboarding in App Store screenshots |
| Browser extension | 1-3 screens on new tab after install; show extension on a real webpage |
| Desktop | First-run wizard; offer "quick start" vs "full setup" |
| Web app | Part of signup flow; progressive profiling; empty states ARE onboarding |

## Related

- `product/ui-design.md` — design standards, animation
- `product/monetisation.md` — paywall placement, pricing
- `product/analytics.md` — onboarding funnel tracking
- `product/validation.md` — competitor onboarding research
- `product/growth.md` — user acquisition channels
