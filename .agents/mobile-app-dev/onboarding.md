---
description: Mobile app onboarding flows - first-run experience, progressive disclosure, user setup
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

# App Onboarding - First Impressions That Convert

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Design onboarding flows that get users to value quickly
- **Principle**: Every screen must earn the right to exist — remove anything that delays the "aha moment"
- **Research**: Study top apps on Mobbin (https://mobbin.com/) for proven onboarding patterns
- **Max screens**: 3-5 (fewer is better)

**Shared with**: `browser-extension-dev.md` (same onboarding principles apply)

<!-- AI-CONTEXT-END -->

## Onboarding Patterns

### Pattern 1: Value-First (Recommended)

Show the app's core value immediately, then ask for setup.

```text
1. Welcome (brand + one-line value prop)
2. Core experience preview (show what the app does)
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

## Design Principles

### Every Screen Must Earn Its Place

Before adding an onboarding screen, ask:

- Does the user need this information to use the app?
- Can this be deferred to later (in-context education)?
- Does this increase the chance they'll become a regular user?

If the answer to all three is "no", remove the screen.

### Skip Option Always Visible

Never trap users in onboarding. Always provide:

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

Exception: If the app's core function requires a permission (e.g., camera app needs camera), request it during onboarding with clear explanation of why.

### Account Creation

Defer account creation unless the app requires it for core functionality:

- **No account needed**: Local-only apps, utilities, tools
- **Optional account**: Sync across devices, social features
- **Required account**: Multi-user, cloud-based, subscription apps

When required, offer:

1. Sign in with Apple (mandatory if any third-party sign-in exists)
2. Sign in with Google
3. Email + password (fallback)

### Paywall Placement

See `mobile-app-dev/monetisation.md` for detailed paywall strategy.

Common onboarding paywall positions:

| Position | Pros | Cons |
|----------|------|------|
| After onboarding, before app | High visibility | User hasn't experienced value |
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
| Permission grant rate | > 60% | Users trust the app |

## Animation and Polish

Onboarding is the app's first impression. Invest in:

- Smooth page transitions (swipe or fade)
- Subtle illustrations or animations (Lottie, Remotion)
- Haptic feedback on key interactions
- Consistent typography and spacing
- Loading states that feel intentional

See `mobile-app-dev/ui-design.md` for animation standards.

## Related

- `mobile-app-dev/ui-design.md` - Design standards
- `mobile-app-dev/monetisation.md` - Paywall placement
- `mobile-app-dev/analytics.md` - Onboarding funnel tracking
