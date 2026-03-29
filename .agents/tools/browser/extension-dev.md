# Browser Extension Dev - Full-Lifecycle Extension Development

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Idea to published browser extension (Chromium + Firefox)
- **Platforms**: Chrome, Edge, Brave, Opera (Chromium-based) + Firefox
- **Framework**: WXT (recommended), Plasmo, or vanilla Manifest V3
- **Lifecycle**: Validation > Architecture > Design > Development > Testing > Publishing > Monetisation > Growth > Iteration

**Framework decision**:

| Choice | When | Notes |
|--------|------|-------|
| **WXT** (recommended) | Cross-browser, React/Vue/Svelte, HMR, auto-imports | TurboStarter uses WXT |
| **Plasmo** | React-focused, simpler API, built-in messaging | Good for React teams |
| **Vanilla MV3** | Maximum control, no framework overhead | Simple extensions |

**Subagents** -- shared product concerns (`product/`):

| Subagent | When to Read |
|----------|--------------|
| `product/validation.md` | Idea validation, market research, competitive analysis |
| `product/onboarding.md` | User onboarding, first-run experience, paywall placement |
| `product/monetisation.md` | Revenue models, paywalls, subscriptions, freemium |
| `product/growth.md` | User acquisition -- UGC, influencers, content, paid ads |
| `product/ui-design.md` | UI/UX design, aesthetics, animations, icons, branding |
| `product/analytics.md` | Usage analytics, feedback loops, crash reporting |

**Subagents** -- extension-specific (`tools/browser/extension-dev/`):

| Subagent | When to Read |
|----------|--------------|
| `development.md` | Project setup, architecture, APIs, cross-browser patterns |
| `testing.md` | Testing, debugging, cross-browser verification |
| `publishing.md` | Chrome Web Store, Firefox Add-ons, Edge Add-ons submission |

**Related**: `chrome-webstore-release.md` (Chrome CI/CD), `playwright.md` (E2E), `browser-automation.md` (tool selection), `tools/vision/overview.md` (icons), `tools/mobile/app-dev.md` (shares product/ subagents)

<!-- AI-CONTEXT-END -->

## Extension Scoping Questions

Before development, determine scope. Read `product/validation.md` for the universal validation framework, then ask:

1. Which browsers? (Chrome-only vs cross-browser)
2. What UI surfaces? (Popup, sidebar, options page, new tab, content overlay)
3. Modify page content? (Content scripts)
4. Background processing? (Service worker)
5. Data persistence? (Local storage, sync storage, backend API)

## Extension Design Constraints

Read `product/ui-design.md` for universal design principles. Extension-specific:

| Surface | Constraint |
|---------|-----------|
| Popup | 300-400px wide, 500-600px tall max (browser-enforced) |
| Sidebar | Full height, 300-400px wide |
| Content overlay | Must not break host page layout |
| Options page | Full page, can be more complex |
| Dark mode | Match browser theme |

## Extension Monetisation

Read `product/monetisation.md` for universal revenue models. Extension-specific:

| Model | Implementation | Notes |
|-------|---------------|-------|
| Freemium | Feature gating via `chrome.storage.sync` | Most common |
| One-time purchase | Stripe + license key validation | Recommended |
| Subscription | Stripe + license key validation | Premium features |
| Donations | Ko-fi, Buy Me a Coffee, GitHub Sponsors | Open-source |
| Affiliate | Links in extension UI or recommendations | Must be transparent |

## Self-Improvement

Tracks: store review feedback, cross-browser compat issues, MV3 API changes, framework updates (WXT, Plasmo). Uses cross-session memory (`/remember`, `/recall`).
