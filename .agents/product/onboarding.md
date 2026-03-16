---
description: Product onboarding flows - first-run experience, progressive disclosure, user setup — applies to mobile apps, browser extensions, web apps, and SaaS
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
- **Principle**: Every step must earn the right to exist — remove anything that delays the "aha moment"
- **Research**: Study top products on Mobbin (https://mobbin.com/) for proven onboarding patterns
- **Max steps**: 3-5 (fewer is better)
- **Applies to**: Mobile apps, browser extensions, web apps, SaaS

<!-- AI-CONTEXT-END -->

## Onboarding Patterns

### Pattern 1: Value-First (Recommended)

Show the product's core value immediately, then ask for setup.

```text
1. Welcome (brand + one-line value prop)
2. Core experience preview (show what the product does)
3. Quick setup (name, preferences — minimal)
4. Permission/access requests (only what's needed now)
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

## Design Principles

### Every Step Must Earn Its Place

Before adding an onboarding step, ask:

- Does the user need this information to use the product?
- Can this be deferred to later (in-context education)?
- Does this increase the chance they'll become a regular user?

If the answer to all three is "no", remove the step.

### Skip Option Always Visible

Never trap users in onboarding. Always provide:

- "Skip" button (top right or bottom)
- Progress indicator (dots or bar)
- Back navigation

### Permission and Access Requests

Request permissions in context, not upfront:

| Permission/Access | When to Ask | Not |
|-------------------|-------------|-----|
| Notifications | After user completes first action | During onboarding |
| Location | When user opens location feature | During onboarding |
| Camera | When user taps camera button | During onboarding |
| Browser permissions (extension) | When user activates feature needing them | During install |
| Integrations (SaaS) | When user sets up the relevant workflow | During signup |

Exception: If the product's core function requires a permission (e.g., a camera app needs camera access), request it during onboarding with clear explanation of why.

### Account Creation

Defer account creation unless the product requires it for core functionality:

- **No account needed**: Local-only tools, utilities
- **Optional account**: Sync across devices, social features
- **Required account**: Multi-user, cloud-based, subscription products

When required, offer:

1. Sign in with Apple (mandatory on iOS if any third-party sign-in exists)
2. Sign in with Google
3. Email + password (fallback)
4. SSO / SAML (for B2B SaaS)

### Paywall Placement

See `product/monetisation.md` for detailed paywall strategy.

Common onboarding paywall positions:

| Position | Pros | Cons |
|----------|------|------|
| After onboarding, before product | High visibility | User hasn't experienced value |
| After first core action | User has experienced value | Lower visibility |
| After 3 days of use | Highest conversion | Delayed revenue |

Recommendation: Show paywall after the user completes their first core action (they've experienced value and want more).

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

- Smooth transitions (swipe or fade)
- Subtle illustrations or animations (Lottie, Remotion)
- Haptic feedback on key interactions (mobile)
- Consistent typography and spacing
- Loading states that feel intentional

See `product/ui-design.md` for animation standards.

## Related

- `product/ui-design.md` - Design standards
- `product/monetisation.md` - Paywall placement
- `product/analytics.md` - Onboarding funnel tracking
