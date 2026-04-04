---
description: App Store and Play Store publishing - submission, compliance, screenshots, metadata, rejection handling
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# App Publishing - Store Submission and Compliance

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Apple**: $99/year — https://developer.apple.com/programs/ (24-48h activation)
- **Google**: $25 one-time — https://play.google.com/console/ (minutes to days)
- **Common rejections**: Missing privacy policy, placeholder content, broken features, guideline violations
- **CLI**: `asc` — see `tools/mobile/app-store-connect.md` for programmatic ASC management

<!-- AI-CONTEXT-END -->

## CLI Automation — asc

```bash
brew install tddworks/tap/asccli
asc auth login --key-id KEY --issuer-id ISSUER --private-key-path ~/.asc/AuthKey.p8
asc apps list
```

## Apple App Store

### Pre-Submission Checklist

**Required**: Active Developer Program membership · App builds without crashes · Privacy policy URL · ToS URL (if applicable) · Description (≤4000 chars) · Keywords (≤100 chars) · Screenshots for required sizes · App icon (1024×1024, no alpha, no rounded corners) · Age rating · Category · Support URL · Review contact info

**If accounts**: Account deletion (required since 2022) · Demo credentials · Sign in with Apple (if any third-party sign-in)

**If payments**: IAP configured in App Store Connect · Subscription terms shown before purchase · Restore purchases button · External payment links: prohibited by default (guideline 3.1.1), but US storefronts now allow them post-2025 Epic ruling; EU storefronts allow them via StoreKit External Purchase Link Entitlement — verify storefront-specific entitlements in App Store Connect before adding

**If social**: Block/report functionality · Content moderation plan · UGC guidelines

### Common Rejection Reasons

| Reason | Guideline | Fix |
|--------|-----------|-----|
| Crashes or bugs | 2.1 | Test on multiple devices |
| Placeholder content | 2.3.3 | Remove lorem ipsum, test data, "coming soon" |
| Incomplete information | 2.1 | Fill all metadata, provide demo credentials |
| Privacy violations | 5.1.1 | Add privacy policy, declare data collection accurately |
| Misleading description | 2.3.1 | Description must match actual functionality |
| No account deletion | 5.1.1 | Add in-app account deletion if accounts exist |
| External payment links | 3.1.1 | Remove unless storefront entitlement granted (US/EU exceptions apply — check App Store Connect) |
| Minimum functionality | 4.2 | App must provide lasting value beyond a simple website |

### Screenshot Requirements

| Device | Size (portrait) | Required |
|--------|-----------------|----------|
| iPhone 6.9" | 1320 × 2868 | Yes (covers 6.7" and 6.9") |
| iPhone 6.5" | 1284 × 2778 | Yes |
| iPad Pro 13" | 2064 × 2752 | If iPad supported |
| iPad Pro 12.9" | 2048 × 2732 | If iPad supported |

Show app in use (not empty states); highlight key features with captions. First screenshot is most important (shown in search). Use Remotion for animated preview videos (≤30 seconds).

### App Review Process

- **Timeline**: 24-48h typically, up to 7 days
- **Expedited review**: Available for critical bug fixes via App Store Connect
- **Rejection**: Fix the cited issue, resubmit with explanation; appeal available

## Google Play Store

### Pre-Submission Checklist

**Required**: Play Developer account · Privacy policy URL · Description (≤4000 chars) · Short description (≤80 chars) · Feature graphic (1024×500) · App icon (512×512) · Screenshots (min 2, up to 8/device type) · Content rating questionnaire · Target audience declarations · Data safety section

**Android-specific**: AAB format (not APK) · Target API level current · 64-bit support · Permissions justified and minimal

### Play Store Review

- **Timeline**: Hours to a few days
- **Policy centre**: Check for violations before submission
- **Pre-launch report**: Review automated device testing results before release

## Metadata Optimisation (ASO)

**App name**: Primary keyword included naturally; ≤30 chars (Apple) / ≤50 chars (Google); brand + keyword pattern.

**Keywords (Apple)**: 100 char limit, comma-separated, no repeats from app name, singular forms, no spaces after commas.

**Description**: First 3 lines visible without "Read More" — lead with core value prop. Short paragraphs, bullets, social proof, CTA.

**Localisation**: Localise metadata for target markets even if app is English-only. Top markets: US, UK, Germany, Japan, Brazil, France.

## Related

- `tools/mobile/app-store-connect.md` — App Store Connect CLI (asc), programmatic ASC management
- `tools/mobile/app-dev/testing.md` — Pre-submission testing
- `product/monetisation.md` — Payment setup
- `tools/mobile/app-dev/assets.md` — Screenshot and icon generation
- `tools/browser/remotion-best-practices-skill.md` — Preview video creation
