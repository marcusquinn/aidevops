# Mobile App Dev - Full-Lifecycle Mobile Application Development

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Guide users from idea to published, revenue-generating mobile app
- **Platforms**: Expo (React Native) for iOS + Android, Swift for iOS-only
- **Lifecycle**: Idea validation -> Planning -> Design -> Development -> Testing -> Publishing -> Monetisation -> Iteration
- **Philosophy**: Open-source first, beautiful by default, user-value driven, self-improving

**Platform decision** (ask user early):

| Choice | When | Framework |
|--------|------|-----------|
| **Expo (default)** | Cross-platform iOS + Android, faster iteration, broader reach | React Native + Expo Router |
| **Swift** | iOS-only, maximum native performance, Apple ecosystem deep integration | SwiftUI + Xcode |

**Key commands**: `/new-app` (start guided flow), `/app-research` (market research), `/app-preview` (simulator preview)

**Subagents** (`mobile-app-dev/`):

| Subagent | When to Read |
|----------|--------------|
| `planning.md` | Idea validation, market research, competitive analysis, feature scoping |
| `expo.md` | Expo/React Native project setup, development, navigation, state management |
| `swift.md` | Swift/SwiftUI project setup, native iOS development, Xcode workflows |
| `ui-design.md` | UI/UX design standards, aesthetics, animations, icons, branding |
| `testing.md` | Simulator/emulator/device testing, E2E flows, accessibility, QA |
| `publishing.md` | App Store/Play Store submission, compliance, screenshots, metadata |
| `monetisation.md` | RevenueCat, paywalls, subscriptions, ads, freemium, affiliate models |
| `onboarding.md` | User onboarding flows, first-run experience, progressive disclosure |
| `analytics.md` | Usage analytics, feedback loops, crash reporting, iteration signals |
| `backend.md` | Backend services, Supabase/Firebase, Coolify self-hosted, APIs |
| `notifications.md` | Push notifications, Expo notifications, local notifications |
| `assets.md` | App icons, splash screens, screenshots, preview videos (Remotion) |

**Related agents**:

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
- `services/accessibility/accessibility-audit.md` - Accessibility compliance
- `browser-extension-dev.md` - Shares planning, UI design, and monetisation subagents

**Existing mobile tool stack**:

```text
Planning     -> mobile-app-dev/planning.md (market research, idea validation)
Development  -> mobile-app-dev/expo.md OR mobile-app-dev/swift.md
UI/UX        -> mobile-app-dev/ui-design.md (aesthetics, animations, icons)
Testing      -> agent-device (AI-driven) + maestro (E2E) + xcodebuild-mcp (build)
Preview      -> ios-simulator-mcp + playwright-emulation (web) + agent-device
Publishing   -> mobile-app-dev/publishing.md (App Store + Play Store)
Monetisation -> mobile-app-dev/monetisation.md (RevenueCat, ads, freemium)
Assets       -> tools/vision/ (icons, graphics) + Remotion (preview videos)
Backend      -> mobile-app-dev/backend.md (Supabase, Firebase, Coolify)
```

<!-- AI-CONTEXT-END -->

## Guided Development Flow

When a user wants to build a mobile app, follow this sequence. Ask focused questions at each stage before proceeding. Do not skip stages or jump ahead.

### Stage 1: Idea Validation

Read `mobile-app-dev/planning.md` for detailed guidance.

**Ask the user**:

1. What problem does this app solve? (Must be a genuine pain point, not a "nice to have")
2. Who experiences this problem? (Target audience)
3. How often do they experience it? (Daily problems = stronger retention)
4. What do they currently do about it? (Existing solutions = market validation)
5. Would they pay to solve it? (Monetisation signal)

**Research existing apps**: Use browser tools to search App Store/Play Store for similar apps. Gather pain points from reviews to identify gaps the new app can fill.

### Stage 2: Platform Decision

**Ask the user**:

1. iOS only, or iOS + Android?
2. Do you need deep Apple ecosystem integration (HealthKit, HomeKit, Siri, widgets)?
3. What's your timeline? (Expo is faster for cross-platform)
4. Do you have an Apple Developer account ($99/year)?
5. Do you have a Google Play Developer account ($25 one-time)?

**Recommendation logic**:

- iOS + Android -> Expo (React Native)
- iOS only + deep native needs -> Swift
- iOS only + speed priority -> Expo (can always port to Swift later)
- Unsure -> Start with Expo, it covers both platforms

### Stage 3: Design and Planning

Read `mobile-app-dev/ui-design.md` for aesthetics standards.

**Before writing any code**:

1. Define the core daily action (the one thing users repeat)
2. Map the onboarding flow (3-5 screens max)
3. Design the main dashboard/home screen
4. Plan navigation structure (tab bar, stack, drawer)
5. Choose colour palette and typography
6. Design the app icon (must stand out among competitors)

**Gather visual inspiration**: Search for UI patterns, competitor screenshots, design systems. Use browser tools to capture reference designs.

### Stage 4: Development

Read the appropriate subagent:

- Expo: `mobile-app-dev/expo.md`
- Swift: `mobile-app-dev/swift.md`

**MVP discipline**: Build the minimum viable product first. One core function, one clean onboarding, one monetisation path. Resist feature creep.

### Stage 5: Testing

Read `mobile-app-dev/testing.md`.

Use the full testing stack:

- `agent-device` for AI-driven interaction testing
- `maestro` for repeatable E2E flows
- `xcodebuild-mcp` for build verification
- `ios-simulator-mcp` for simulator QA
- `playwright-emulation` for web-based mobile preview
- Physical device testing via TestFlight (iOS) or internal testing (Android)

### Stage 6: Publishing

Read `mobile-app-dev/publishing.md`.

Covers App Store and Play Store submission, compliance requirements, screenshot generation, metadata optimisation, and common rejection reasons.

### Stage 7: Monetisation and Growth

Read `mobile-app-dev/monetisation.md`.

Covers RevenueCat integration, paywall design, subscription tiers, ad-supported models, freemium strategies, and affiliate/funnel approaches.

### Stage 8: Iteration

Read `mobile-app-dev/analytics.md`.

Use analytics and user feedback to iterate. Track retention, engagement, crash rates, and feature usage. Prioritise improvements based on data.

## Self-Improvement

This agent suite improves based on:

- Development outcomes (what worked, what failed)
- App Store review feedback (common rejections)
- User testing results (UX issues discovered)
- New tool capabilities (framework updates, new APIs)
- Pattern tracking via `pattern-tracker-helper.sh`

Use `/remember` to capture learnings across sessions.
