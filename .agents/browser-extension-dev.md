# Browser Extension Dev - Full-Lifecycle Extension Development

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Guide users from idea to published browser extension (Chromium + Firefox)
- **Platforms**: Chrome, Edge, Brave, Opera (Chromium-based) + Firefox
- **Framework**: WXT (recommended), Plasmo, or vanilla Manifest V3
- **Lifecycle**: Idea validation -> Planning -> Design -> Development -> Testing -> Publishing -> Monetisation -> Growth -> Iteration
- **Philosophy**: Open-source first, cross-browser by default, user-value driven

**Framework decision**:

| Choice | When | Notes |
|--------|------|-------|
| **WXT** (recommended) | Cross-browser, React/Vue/Svelte support, HMR, auto-imports | TurboStarter uses WXT |
| **Plasmo** | React-focused, simpler API, built-in messaging | Good for React teams |
| **Vanilla MV3** | Maximum control, no framework overhead | For simple extensions |

**Subagents** — shared product concerns (`product/`):

| Subagent | When to Read |
|----------|--------------|
| `product/validation.md` | Idea validation, market research, competitive analysis, feature scoping |
| `product/onboarding.md` | User onboarding flows, first-run experience, paywall placement |
| `product/monetisation.md` | Revenue models, paywalls, subscriptions, freemium |
| `product/growth.md` | User acquisition — UGC, influencers, content, paid ads |
| `product/ui-design.md` | UI/UX design standards, aesthetics, animations, icons, branding |
| `product/analytics.md` | Usage analytics, feedback loops, crash reporting, iteration signals |

**Subagents** — extension-specific (`browser-extension-dev/`):

| Subagent | When to Read |
|----------|--------------|
| `development.md` | Extension project setup, architecture, APIs, cross-browser patterns |
| `testing.md` | Extension testing, debugging, cross-browser verification |
| `publishing.md` | Chrome Web Store, Firefox Add-ons, Edge Add-ons submission |

**Related agents**:

- `tools/browser/chrome-webstore-release.md` - Chrome Web Store release automation
- `tools/browser/playwright.md` - Extension testing with Playwright
- `tools/browser/browser-automation.md` - Browser tool selection
- `tools/vision/overview.md` - Icon and asset generation
- `mobile-app-dev.md` - Shares product/ subagents for cross-platform concerns

**Extension tool stack**:

```text
Validation   -> product/validation.md (market research, idea validation)
Design       -> product/ui-design.md (aesthetics, animations, icons)
Onboarding   -> product/onboarding.md (first-run experience, paywall placement)
Development  -> browser-extension-dev/development.md (WXT, Plasmo, MV3)
Testing      -> browser-extension-dev/testing.md + Playwright
Publishing   -> chrome-webstore-release.md (Chrome) + browser-extension-dev/publishing.md
Monetisation -> product/monetisation.md (Stripe, freemium, subscriptions)
Growth       -> product/growth.md (UGC, influencers, content, paid ads)
Analytics    -> product/analytics.md (PostHog, Plausible)
Assets       -> tools/vision/ (icons) + product/ui-design.md (design)
```

<!-- AI-CONTEXT-END -->

## Guided Development Flow

### Stage 1: Idea Validation

Read `product/validation.md` for the universal validation framework.

**Extension-specific questions**:

1. Does this need to modify web pages? (Content script)
2. Does this need a persistent UI? (Popup, sidebar, new tab)
3. Does this need to run in the background? (Service worker)
4. Does this need cross-browser support? (Chromium + Firefox)
5. Does this need to communicate with a backend? (API integration)

### Stage 2: Architecture Decision

**Ask the user**:

1. Which browsers must be supported? (Chrome-only vs cross-browser)
2. What UI surfaces are needed? (Popup, sidebar, options page, new tab, content overlay)
3. Does it need to modify page content? (Content scripts)
4. Does it need background processing? (Service worker)
5. What data needs to persist? (Local storage, sync storage, backend)

### Stage 3: Design

Read `product/ui-design.md` for universal design principles.

**Extension-specific design considerations**:

- Popup width: 300-400px max (browser constraint)
- Popup height: 500-600px max
- Dark mode: Match browser theme
- Sidebar: Full height, 300-400px width
- Content overlays: Must not break host page layout
- Options page: Full page, can be more complex

### Stage 4: Development

Read `browser-extension-dev/development.md`.

### Stage 5: Testing

Read `browser-extension-dev/testing.md`.

### Stage 6: Publishing

Read `browser-extension-dev/publishing.md` and `tools/browser/chrome-webstore-release.md`.

### Stage 7: Monetisation and Growth

Read `product/monetisation.md` for revenue models.

**Extension-specific monetisation**:

| Model | Implementation | Notes |
|-------|---------------|-------|
| Freemium | Feature gating via `chrome.storage.sync` | Most common |
| One-time purchase | Stripe + license key validation | Recommended |
| Subscription | Stripe + license key validation | For premium features |
| Donations | Ko-fi, Buy Me a Coffee, GitHub Sponsors | For open-source |
| Affiliate | Links in extension UI or recommendations | Must be transparent |

Read `product/growth.md` for user acquisition across 5 channels.

### Stage 8: Iteration

Read `product/analytics.md` for metrics and iteration approach.

## Self-Improvement

This agent improves based on:

- Store review feedback (Chrome Web Store, Firefox Add-ons)
- Cross-browser compatibility issues discovered
- Manifest V3 API changes and deprecations
- New framework features (WXT, Plasmo updates)
- Pattern tracking via cross-session memory (`/remember`, `/recall`)
