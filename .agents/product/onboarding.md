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

# Product Onboarding - First Impressions That Convert

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Get users to value quickly — every screen must earn its place
- **Research**: Study top products on Mobbin (https://mobbin.com/) for proven patterns
- **Max screens**: 3-5 (fewer is better)
- **Applies to**: Mobile apps, browser extensions, desktop apps, web apps

<!-- AI-CONTEXT-END -->

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

**When to use**: B2C where competitors use hard paywalls. Validate against top-grossing competitors.

| Aspect | Hard Paywall | Soft Paywall (feature-gated) |
|--------|-------------|------------------------------|
| Revenue per install | Higher | Lower |
| Conversion rate | Lower (many bounce) | Higher (more try first) |
| User quality | Higher (committed users) | Mixed |
| App Store ratings | Risk of negative reviews | Generally better |
| Best for | Proven niches with validated demand | New/unvalidated products |

**Key principle**: Weak onboarding + hard paywall drives users away. Strong onboarding + hard paywall maximises revenue. Mirror top competitor pricing; A/B test once you have traffic.

## Design Principles

**Every screen must earn its place** — add a screen only if the user needs the information now, it can't be deferred, and it increases the chance they become a regular user.

**Skip always visible** (except hard paywall): "Skip" button, progress indicator, back navigation.

### Permission Requests

Request in context, not upfront. Exception: if the core function requires a permission (e.g., camera app), request during onboarding with a clear explanation.

| Permission | When to Ask |
|------------|-------------|
| Notifications | After user completes first action |
| Location | When user opens map/location feature |
| Camera | When user taps camera button |
| Health data | When user enables health tracking |
| Browser permissions | When user triggers the feature needing it |

### Account Creation

Defer unless required for core functionality:

- **No account**: Local-only products, utilities, tools
- **Optional**: Sync across devices, social features
- **Required**: Multi-user, cloud-based, subscription products

When required: Sign in with Apple (mandatory on iOS if any third-party sign-in exists) → Sign in with Google → Email + password.

### Paywall Placement

See `product/monetisation.md` for detailed strategy. If competitors use hard paywalls successfully, follow their lead; otherwise show paywall after first core action.

| Position | Pros | Cons |
|----------|------|------|
| After onboarding, before product (hard) | High visibility, maximises revenue per install | User hasn't experienced value |
| After first core action (soft) | User has experienced value | Lower visibility |
| After 3 days of use (delayed) | Highest conversion | Delayed revenue |

## Onboarding Metrics

| Metric | Target | Meaning |
|--------|--------|---------|
| Completion rate | > 80% | Users finish onboarding |
| Time to complete | < 60 seconds | Not too long |
| Day 1 retention | > 40% | Users come back |
| Day 7 retention | > 20% | Users form habit |
| Permission grant rate | > 60% | Users trust the product |

## Platform Notes

| Platform | Key considerations |
|----------|--------------------|
| Mobile | Full-screen swipeable screens; haptic feedback; show onboarding in App Store screenshots |
| Browser extension | 1-3 screens on new tab after install; show extension in action on a real webpage |
| Desktop | First-run wizard; offer "quick start" vs "full setup" |
| Web app | Part of signup flow; progressive profiling; empty states ARE onboarding — design them to guide action |

## Animation and Polish

Onboarding is the product's first impression — invest in smooth transitions, subtle animations (Lottie, Remotion), haptic feedback (mobile), and intentional loading states. See `product/ui-design.md` for standards.

## Related

- `product/ui-design.md` - Design standards and animation
- `product/monetisation.md` - Paywall placement and pricing
- `product/analytics.md` - Onboarding funnel tracking
- `product/validation.md` - Competitor onboarding research
- `product/growth.md` - User acquisition channels
