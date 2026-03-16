---
description: Product idea validation, market research, competitive analysis, and feature scoping — applies to mobile apps, browser extensions, web apps, and SaaS
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

# Product Validation - Idea to Specification

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate product ideas, research markets, analyse competitors, scope features
- **Output**: Validated idea + feature spec + design brief ready for development
- **Tools**: Browser (store/web research), web search (market data), crawl4ai (review scraping)
- **Applies to**: Mobile apps, browser extensions, web apps, SaaS, CLI tools

<!-- AI-CONTEXT-END -->

## Idea Validation Framework

### Painkiller vs Vitamin Test

Strong product ideas solve painful, frequent problems. Weak ideas are "nice to have."

**Painkiller criteria** (need 3+ of these):

- Solves something uncomfortable or embarrassing
- Problem occurs daily or multiple times per week
- People are already trying to fix it (with workarounds, other tools, manual effort)
- Creates emotional urgency (guilt, fear, frustration, shame, urgency)
- People would pay to make it go away

**Red flags** (likely a vitamin, not a painkiller):

- "It would be cool if..."
- No existing solutions (may mean no real demand)
- Solves a problem the builder has but nobody else mentions
- Requires educating users about why they need it

### Market Research Process

1. **Search stores and directories** for similar products using browser tools
2. **Read 1-star and 2-star reviews** of competitors — these reveal unmet needs
3. **Read 5-star reviews** — these reveal what users value most
4. **Check download/install counts and ratings** — validates market size
5. **Search social media** for complaints about the problem domain
6. **Check Google Trends** for search volume on related terms

### Competitive Analysis Template

For each competitor product, capture:

| Field | What to Record |
|-------|---------------|
| Name | Product name and developer |
| Rating | Average rating and review count |
| Price | Free, freemium, paid, subscription |
| Core feature | The one thing it does best |
| Top complaints | From 1-2 star reviews |
| Missing features | What users ask for but don't get |
| UI quality | Screenshots, design quality assessment |
| Last updated | Active development signal |

### Feature Scoping

**MVP rules**:

- One core daily action (the heart of the product)
- One clean onboarding flow (3-5 steps)
- One monetisation path (even if free initially)
- No social features in v1 (unless social IS the core)
- No settings screen in v1 (sensible defaults)
- No account system in v1 (unless data sync is core)

**Feature prioritisation**:

| Priority | Criteria | Example |
|----------|----------|---------|
| P0 - Must have | Product doesn't work without it | Core action, basic navigation |
| P1 - Should have | Significantly improves core experience | Notifications, progress tracking |
| P2 - Nice to have | Enhances but not essential | Themes, sharing, export |
| P3 - Future | Save for v2+ | Social features, integrations, widgets |

### Output: Product Specification

After validation, produce a specification covering:

1. **Problem statement**: One paragraph describing the pain point
2. **Target user**: Demographics, psychographics, usage context
3. **Core daily action**: The one thing users repeat
4. **Feature list**: Prioritised P0-P3
5. **Monetisation model**: How the product makes money
6. **Platform**: Which surface(s) to target (mobile, extension, web, desktop)
7. **Design brief**: Colour palette, typography, mood, reference products
8. **Success metrics**: What "working" looks like (installs, retention, revenue)

## Design Research

Before development, gather visual inspiration. See `tools/design/design-inspiration.md` for the full catalogue of 60+ resources.

**Quick workflow**:

1. **Search Mobbin** (https://mobbin.com) for your product category — study onboarding flows, navigation patterns, paywall designs, and empty states from top-rated apps
2. **Browse Screenlane** (https://screenlane.com) for free UI screenshots by component type
3. **Search Pinterest** for mood boards: "minimal app UI", "dark onboarding flow", "SaaS dashboard design"
4. **Select 4-5 design components** you like (onboarding screens, typography, colours, progress bars, card layouts)
5. **Capture screenshots** using browser tools for reference during development

## Store and Directory Research

### Searching Stores and Directories

Use browser tools to search:

- Apple App Store: `https://apps.apple.com/search?term={query}`
- Google Play Store: `https://play.google.com/store/search?q={query}`
- Chrome Web Store: `https://chromewebstore.google.com/search/{query}`
- Product Hunt: `https://www.producthunt.com/search?q={query}`
- AlternativeTo: `https://alternativeto.net/software/{product-name}/`
- G2 / Capterra: For SaaS competitive research

### Gathering Reviews

Use crawl4ai or browser tools to extract reviews. Focus on:

- **Pain points**: What frustrates users about existing products?
- **Feature requests**: What do users wish the product could do?
- **Praise patterns**: What do users love? (Don't break these)
- **Pricing complaints**: Is the market price-sensitive?

### Trend Analysis

- Google Trends for search interest over time
- App Annie / Sensor Tower (if accessible) for mobile download estimates
- Reddit/Twitter for community sentiment
- YouTube for "best X tool" review videos (shows what reviewers value)

## Related

- `product/ui-design.md` - Design standards
- `product/monetisation.md` - Revenue model selection
- `product/onboarding.md` - First-run experience design
- `product/growth.md` - Acquisition and growth playbook
