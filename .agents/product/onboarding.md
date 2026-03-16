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

- **Purpose**: Design onboarding flows that get users to value quickly
- **Principle**: Every screen must earn the right to exist — remove anything that delays the "aha moment"
- **Research**: Study top products on Mobbin (https://mobbin.com/) for proven onboarding patterns
- **Max screens**: 3-5 (fewer is better)
- **Applies to**: Mobile apps, browser extensions, desktop apps, web apps

<!-- AI-CONTEXT-END -->

## Onboarding Patterns

### Pattern 1: Value-First (Recommended for most products)

Show the product's core value immediately, then ask for setup.

```text
1. Welcome (brand + one-line value prop)
2. Core experience preview (show what the product does)
3. Quick setup (name, preferences — minimal)
4. Permission requests (only what's needed now)
5. Ready screen (clear CTA to start using)
```

### Pattern 2: Progressive Setup

Collect information needed to personalise the experience.

```text
1. Welcome
2. "What's your goal?" (personalisation question)
3. "How often?" (frequency/commitment)
4. Personalised preview (show tailored experience)
5. Account creation (optional, defer if possible)
```

### Pattern 3: Feature Tour

Walk through key features with interactive demos.

```text
1. Welcome
2. Feature 1 demo (interactive, not just text)
3. Feature 2 demo
4. "You're ready" (summary of what they can do)
```

### Pattern 4: Hard Paywall (High-revenue B2C pattern)

Force a payment decision immediately after onboarding, before any product usage. Used by many top-grossing consumer apps.

```text
1. Welcome (brand + bold value prop)
2. "What's your goal?" (personalisation — builds investment)
3. Problem reminder (why they downloaded/installed)
4. Solution preview (how the product solves it)
5. Social proof (user count, testimonials, ratings)
6. Hard paywall (unskippable — pay or start free trial)
```

**When to use**: B2C products where competitors successfully use hard paywalls (validate by checking top-grossing competitors). Works best when the onboarding itself builds enough perceived value that users feel invested before hitting the paywall.

**Trade-offs**:

| Aspect | Hard Paywall | Soft Paywall (feature-gated) |
|--------|-------------|------------------------------|
| Revenue per install | Higher | Lower |
| Conversion rate | Lower (many bounce) | Higher (more try first) |
| User quality | Higher (committed users) | Mixed |
| App Store ratings | Risk of negative reviews | Generally better |
| Best for | Proven niches with validated demand | New/unvalidated products |

**Key principle**: The onboarding before the paywall must remind users why they came, make them feel the problem, and position the product as the solution. If the onboarding is weak, a hard paywall just drives users away. If the onboarding is strong, a hard paywall maximises revenue from motivated users.

**Pricing on hard paywalls**: Mirror competitor pricing. If the top 3 competitors charge $4.99/week with a 3-day free trial, start there. Use A/B testing to optimise once you have traffic.

## Design Principles

### Every Screen Must Earn Its Place

Before adding an onboarding screen, ask:

- Does the user need this information to use the product?
- Can this be deferred to later (in-context education)?
- Does this increase the chance they'll become a regular user?

If the answer to all three is "no", remove the screen.

### Skip Option Always Visible

Never trap users in onboarding (except for hard paywall pattern where the paywall itself is intentionally unskippable). Always provide:

- "Skip" button (top right or bottom)
- Progress indicator (dots or bar)
- Back navigation

### Permission Requests

Request permissions in context, not upfront:

| Permission | When to Ask | Not |
|------------|-------------|-----|
| Notifications | After user completes first action | During onboarding |
| Location | When user opens map/location feature | During onboarding |
| Camera | When user taps camera button | During onboarding |
| Health data | When user enables health tracking | During onboarding |
| Browser permissions | When user triggers the feature needing it | During install |

Exception: If the product's core function requires a permission (e.g., camera app needs camera), request it during onboarding with clear explanation of why.

### Account Creation

Defer account creation unless the product requires it for core functionality:

- **No account needed**: Local-only products, utilities, tools
- **Optional account**: Sync across devices, social features
- **Required account**: Multi-user, cloud-based, subscription products

When required, offer:

1. Sign in with Apple (mandatory on iOS if any third-party sign-in exists)
2. Sign in with Google
3. Email + password (fallback)

### Paywall Placement

See `product/monetisation.md` for detailed paywall strategy.

Common onboarding paywall positions:

| Position | Pros | Cons |
|----------|------|------|
| After onboarding, before product (hard) | High visibility, maximises revenue per install | User hasn't experienced value |
| After first core action (soft) | User has experienced value | Lower visibility |
| After 3 days of use (delayed) | Highest conversion | Delayed revenue |

Recommendation depends on niche validation — if competitors use hard paywalls successfully, follow their lead. For unvalidated products, show the paywall after the user completes their first core action.

## Onboarding Metrics

Track these to optimise:

| Metric | Target | Meaning |
|--------|--------|---------|
| Completion rate | > 80% | Users finish onboarding |
| Time to complete | < 60 seconds | Not too long |
| Day 1 retention | > 40% | Users come back |
| Day 7 retention | > 20% | Users form habit |
| Permission grant rate | > 60% | Users trust the product |

## Animation and Polish

Onboarding is the product's first impression. Invest in:

- Smooth page transitions (swipe or fade)
- Subtle illustrations or animations (Lottie, Remotion)
- Haptic feedback on key interactions (mobile)
- Consistent typography and spacing
- Loading states that feel intentional

See `product/ui-design.md` for animation standards.

## Platform-Specific Notes

### Mobile Apps

- Onboarding screens are full-screen, swipeable
- Haptic feedback enhances perceived quality
- App Store screenshots should show onboarding highlights

### Browser Extensions

- Onboarding often happens on a new tab page after install
- Keep it shorter (1-3 screens) — extension users expect quick setup
- Show the extension in action on a real webpage

### Desktop Apps

- First-run wizard or welcome window
- Can be more detailed than mobile (larger screen)
- Consider a "quick start" vs "full setup" option

### Web Apps

- Onboarding is part of the signup flow
- Progressive profiling (ask more over time, not all upfront)
- Empty states ARE onboarding — design them to guide action

## Related

- `product/ui-design.md` - Design standards
- `product/monetisation.md` - Paywall placement and pricing
- `product/analytics.md` - Onboarding funnel tracking
- `product/validation.md` - Competitor onboarding research
- `product/growth.md` - User acquisition channels
