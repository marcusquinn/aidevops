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

The checklists below cover compliance requirements. The `asc` CLI automates execution.

## Apple App Store

### Pre-Submission Checklist

**Required**:

- [ ] Active Apple Developer Program membership
- [ ] App builds and runs without crashes
- [ ] Privacy policy URL (hosted, accessible)
- [ ] App Store description (up to 4000 chars), keywords (up to 100 chars)
- [ ] Screenshots for required device sizes; app icon (1024x1024, no alpha, no rounded corners)
- [ ] Age rating questionnaire, app category, support URL, contact info for review team

**If accounts**: account deletion (required since 2022), demo credentials, Sign in with Apple (if any third-party sign-in)

**If payments**: IAP configured in ASC, subscription terms before purchase, restore purchases button, no external payment links (guideline 3.1.1)

**If social features**: block/report functionality, content moderation plan, UGC guidelines

### Common Rejection Reasons

| Reason | Guideline | Fix |
|--------|-----------|-----|
| Crashes or bugs | 2.1 | Test on multiple devices |
| Placeholder content | 2.3.3 | Remove lorem ipsum, test data, "coming soon" |
| Incomplete information | 2.1 | Fill all metadata, provide demo credentials |
| Privacy violations | 5.1.1 | Add privacy policy, declare data collection accurately |
| Misleading description | 2.3.1 | Description must match actual functionality |
| No account deletion | 5.1.1 | Add in-app account deletion if accounts exist |
| External payment links | 3.1.1 | Remove links to external payment methods |
| Minimum functionality | 4.2 | App must provide lasting value beyond a simple website |

### Screenshot Requirements

| Device | Size (portrait) | Required |
|--------|-----------------|----------|
| iPhone 6.9" | 1320 x 2868 | Yes (covers 6.7" and 6.9") |
| iPhone 6.5" | 1284 x 2778 | Yes |
| iPad Pro 13" | 2064 x 2752 | If iPad supported |
| iPad Pro 12.9" | 2048 x 2732 | If iPad supported |

Show app in use (not empty states). First screenshot is most important (shown in search). Use Remotion for animated preview videos (up to 30 seconds).

### App Review Process

- **Timeline**: 24-48 hours typically, up to 7 days
- **Expedited review**: Available for critical bug fixes via App Store Connect
- **Rejection**: Fix the specific issue cited, resubmit with explanation; appeal available

## Google Play Store

### Pre-Submission Checklist

**Required**:

- [ ] Privacy policy URL
- [ ] App description (up to 4000 chars), short description (up to 80 chars)
- [ ] Feature graphic (1024 x 500), app icon (512 x 512)
- [ ] Screenshots (min 2, up to 8 per device type)
- [ ] Content rating questionnaire, target audience declarations, data safety section

**Android-specific**: AAB format (not APK), target API level current, 64-bit support, minimal justified permissions

### Play Store Review

- **Timeline**: Hours to a few days
- **Pre-launch report**: Automated testing on multiple devices — review results before release

## Metadata Optimisation (ASO)

**App name**: Primary keyword naturally included; ≤30 chars (Apple) / ≤50 chars (Google); brand + keyword pattern.

**Keywords (Apple)**: 100 char limit, comma-separated, no repeats from app name, singular forms, no spaces after commas.

**Description**: First 3 lines visible without "Read More" — lead with core value proposition. Short paragraphs, bullet points, social proof, call to action.

**Localisation**: Localise metadata for target markets even if app is English-only. Localised screenshots improve conversion. Top markets: US, UK, Germany, Japan, Brazil, France.

## Related

- `tools/mobile/app-store-connect.md` — App Store Connect CLI (asc), programmatic ASC management
- `tools/mobile/app-dev/testing.md` — Pre-submission testing
- `product/monetisation.md` — Payment setup
- `tools/mobile/app-dev/assets.md` — Screenshot and icon generation
- `tools/browser/remotion-best-practices-skill.md` — Preview video creation
