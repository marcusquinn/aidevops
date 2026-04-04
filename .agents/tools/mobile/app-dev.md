<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mobile App Dev - Full-Lifecycle Mobile Application Development

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Guide users from idea to published, revenue-generating mobile app
- **Platforms**: Expo (React Native) for iOS + Android, Swift for iOS-only
- **Lifecycle**: Idea validation → Planning → Design → Development → Testing → Publishing → Monetisation → Growth → Iteration
- **Philosophy**: Open-source first, beautiful by default, user-value driven, self-improving
- **Key commands**: `/new-app` (start guided flow), `/app-research` (market research), `/app-preview` (simulator preview)

**Platform decision** (ask user early):

| Choice | When | Framework |
|--------|------|-----------|
| **Expo (default)** | Cross-platform iOS + Android, faster iteration, broader reach | React Native + Expo Router |
| **Swift** | iOS-only, maximum native performance, Apple ecosystem deep integration | SwiftUI + Xcode |

**Subagents** — shared product concerns (`product/`):

| Subagent | When to Read |
|----------|--------------|
| `product/validation.md` | Idea validation, market research, competitive analysis, feature scoping |
| `product/onboarding.md` | User onboarding flows, first-run experience, paywall placement |
| `product/monetisation.md` | Revenue models, paywalls, subscriptions, ads, freemium |
| `product/growth.md` | User acquisition — UGC, influencers, content, paid ads |
| `product/ui-design.md` | UI/UX design standards, aesthetics, animations, icons, branding |
| `product/analytics.md` | Usage analytics, feedback loops, crash reporting, iteration signals |

**Subagents** — mobile-specific (`tools/mobile/app-dev/`):

| Subagent | When to Read |
|----------|--------------|
| `expo.md` | Expo/React Native project setup, development, navigation, state management |
| `swift.md` | Swift/SwiftUI project setup, native iOS development, Xcode workflows |
| `testing.md` | Simulator/emulator/device testing, E2E flows, accessibility, QA |
| `publishing.md` | App Store/Play Store submission, compliance, screenshots, metadata |
| `backend.md` | Backend services, Supabase/Firebase, Coolify self-hosted, APIs |
| `notifications.md` | Push notifications, Expo notifications, local notifications |
| `assets.md` | App icons, splash screens, screenshots, preview videos (Remotion) |

**Related agents**:

- `tools/mobile/app-store-connect.md` - App Store Connect CLI (asc) — builds, TestFlight, metadata, subscriptions, submissions, web dashboard
- `tools/mobile/agent-device.md` - AI-driven mobile device automation
- `tools/mobile/xcodebuild-mcp.md` - Xcode build/test/deploy
- `tools/mobile/maestro.md` - E2E test flows
- `tools/mobile/ios-simulator-mcp.md` - iOS simulator interaction
- `tools/mobile/minisim.md` - Simulator launcher
- `tools/browser/playwright-emulation.md` - Mobile web preview
- `tools/design/design-inspiration.md` - 60+ UI/UX design inspiration resources
- `tools/browser/remotion-best-practices-skill.md` - Animated previews and App Store videos
- `tools/vision/overview.md` - Image generation for app assets
- `tools/deployment/coolify.md` - Self-hosted backend deployment
- `tools/accessibility/accessibility-audit.md` - Accessibility compliance
- `tools/browser/extension-dev.md` - Shares product/ subagents for cross-platform concerns

<!-- AI-CONTEXT-END -->

## Guided Development Flow

Follow this sequence when a user wants to build a mobile app. Ask focused questions at each stage before proceeding. Do not skip stages or jump ahead.

### Stage 1: Idea Validation (`product/validation.md`)

Ask: (1) What problem does this solve? (genuine pain point, not "nice to have") (2) Who experiences it? (3) How often? (daily = stronger retention) (4) What do they currently do? (existing solutions = market validation) (5) Would they pay?

Search App Store/Play Store for similar apps. Gather review pain points to identify gaps.

### Stage 2: Platform Decision

| Signal | Recommendation |
|--------|---------------|
| iOS + Android | Expo (React Native) |
| iOS only + deep native needs (HealthKit, HomeKit, Siri, widgets) | Swift |
| iOS only + speed priority | Expo (can port to Swift later) |
| Unsure | Expo — covers both platforms |

Ask: (1) iOS only or iOS + Android? (2) Deep Apple ecosystem integration needed? (3) Timeline? (4) Apple Developer account ($99/year)? (5) Google Play account ($25 one-time)?

### Stage 3: Design and Planning (`product/ui-design.md`)

Before writing any code: (1) Define the core daily action (the one thing users repeat) (2) Map onboarding flow (3-5 screens max — `product/onboarding.md`) (3) Design main dashboard/home screen (4) Plan navigation structure (tab bar, stack, drawer) (5) Choose colour palette and typography (6) Design app icon (must stand out among competitors)

Search for UI patterns, competitor screenshots, design systems using browser tools.

### Stage 4: Development

- Expo: `tools/mobile/app-dev/expo.md`
- Swift: `tools/mobile/app-dev/swift.md`

**MVP discipline**: One core function, one clean onboarding, one monetisation path. Resist feature creep.

### Stage 5: Testing (`tools/mobile/app-dev/testing.md`)

Full testing stack: `agent-device` (AI-driven interaction) + `maestro` (repeatable E2E) + `xcodebuild-mcp` (build verification) + `ios-simulator-mcp` (simulator QA) + `playwright-emulation` (web-based mobile preview) + physical device via TestFlight (iOS) or internal testing (Android).

### Stage 6: Publishing (`tools/mobile/app-dev/publishing.md`)

App Store and Play Store submission, compliance, screenshot generation, metadata optimisation, common rejection reasons.

### Stage 7: Monetisation and Growth

- Revenue models and paywall design: `product/monetisation.md`
- User acquisition (UGC creators, influencers, faceless content, founder-led content, paid ads): `product/growth.md`

### Stage 8: Iteration (`product/analytics.md`)

Track retention, engagement, crash rates, and feature usage. Prioritise improvements based on data. Use `/remember` to capture learnings across sessions.
