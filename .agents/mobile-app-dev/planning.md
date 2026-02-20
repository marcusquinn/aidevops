---
description: Mobile app idea validation, market research, competitive analysis, and feature scoping
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Mobile App Planning - Idea to Specification

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate app ideas, research markets, analyse competitors, scope features
- **Output**: Validated idea + feature spec + design brief ready for development
- **Tools**: Browser (app store research), web search (market data), crawl4ai (review scraping)

**Shared with**: `browser-extension-dev.md` (same planning principles apply)

<!-- AI-CONTEXT-END -->

## Idea Validation Framework

### Painkiller vs Vitamin Test

Strong app ideas solve painful, frequent problems. Weak ideas are "nice to have."

**Painkiller criteria** (need 3+ of these):

- Solves something uncomfortable or embarrassing
- Problem occurs daily or multiple times per week
- People are already trying to fix it (with workarounds, other apps, manual effort)
- Creates emotional urgency (guilt, fear, frustration, shame, urgency)
- People would pay to make it go away

**Red flags** (likely a vitamin, not a painkiller):

- "It would be cool if..."
- No existing solutions (may mean no real demand)
- Solves a problem the builder has but nobody else mentions
- Requires educating users about why they need it

### Market Research Process

1. **Search app stores** for similar apps using browser tools
2. **Read 1-star and 2-star reviews** of competitors — these reveal unmet needs
3. **Read 5-star reviews** — these reveal what users value most
4. **Check download counts and ratings** — validates market size
5. **Search social media** for complaints about the problem domain
6. **Check Google Trends** for search volume on related terms

### Competitive Analysis Template

For each competitor app, capture:

| Field | What to Record |
|-------|---------------|
| Name | App name and developer |
| Rating | Average rating and review count |
| Price | Free, freemium, paid, subscription |
| Core feature | The one thing it does best |
| Top complaints | From 1-2 star reviews |
| Missing features | What users ask for but don't get |
| UI quality | Screenshots, design quality assessment |
| Last updated | Active development signal |

### Feature Scoping

**MVP rules**:

- One core daily action (the heart of the app)
- One clean onboarding flow (3-5 screens)
- One monetisation path (even if free initially)
- No social features in v1 (unless social IS the core)
- No settings screen in v1 (sensible defaults)
- No account system in v1 (unless data sync is core)

**Feature prioritisation**:

| Priority | Criteria | Example |
|----------|----------|---------|
| P0 - Must have | App doesn't work without it | Core daily action, basic navigation |
| P1 - Should have | Significantly improves core experience | Streak tracking, notifications |
| P2 - Nice to have | Enhances but not essential | Themes, sharing, export |
| P3 - Future | Save for v2+ | Social features, integrations, widgets |

### Output: App Specification

After planning, produce a specification covering:

1. **Problem statement**: One paragraph describing the pain point
2. **Target user**: Demographics, psychographics, usage context
3. **Core daily action**: The one thing users repeat
4. **Feature list**: Prioritised P0-P3
5. **Monetisation model**: How the app makes money
6. **Platform**: Expo or Swift (with rationale)
7. **Design brief**: Colour palette, typography, mood, reference apps
8. **Success metrics**: What "working" looks like (downloads, retention, revenue)

## Design Research

Before development, gather visual inspiration. See `tools/design/design-inspiration.md` for the full catalogue of 60+ resources.

**Quick workflow**:

1. **Search Mobbin** (https://mobbin.com) for your app category — study onboarding flows, navigation patterns, paywall designs, and empty states from top-rated apps
2. **Browse Screenlane** (https://screenlane.com) for free mobile UI screenshots by component type
3. **Search Pinterest** for mood boards: "minimal iOS app UI", "dark onboarding flow", "mobile paywall design"
4. **Select 4-5 design components** you like (onboarding screens, typography, colours, progress bars, card layouts)
5. **Capture screenshots** using browser tools for reference during development

## App Store Research Techniques

### Searching App Stores

Use browser tools to search:

- Apple App Store: `https://apps.apple.com/search?term={query}`
- Google Play Store: `https://play.google.com/store/search?q={query}`
- Product Hunt: `https://www.producthunt.com/search?q={query}`
- AlternativeTo: `https://alternativeto.net/software/{app-name}/`

### Gathering Reviews

Use crawl4ai or browser tools to extract reviews. Focus on:

- **Pain points**: What frustrates users about existing apps?
- **Feature requests**: What do users wish the app could do?
- **Praise patterns**: What do users love? (Don't break these)
- **Pricing complaints**: Is the market price-sensitive?

### Trend Analysis

- Google Trends for search interest over time
- App Annie / Sensor Tower (if accessible) for download estimates
- Reddit/Twitter for community sentiment
- YouTube for "best X app" review videos (shows what reviewers value)
