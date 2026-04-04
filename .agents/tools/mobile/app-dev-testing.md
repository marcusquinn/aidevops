---
description: Mobile app testing - simulator, emulator, device, E2E, accessibility, QA workflows
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mobile App Testing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Levels**: Unit → Integration → E2E → Visual → Accessibility → Performance
- **Tool decision**:

```text
AI-driven exploratory?     -> agent-device (CLI, both platforms)
Repeatable E2E flows?      -> maestro (YAML, flakiness tolerance)
Build/test/deploy iOS?     -> xcodebuild-mcp (Xcode, LLDB)
iOS simulator interaction? -> ios-simulator-mcp (tap/swipe/type/screenshot)
Mobile web layout?         -> playwright-emulation (device presets, touch)
```

<!-- AI-CONTEXT-END -->

## Testing Strategy

**Unit**: Expo → Jest + React Native Testing Library. Swift → XCTest (`xcodebuild-mcp test_sim`). Cover: business logic, data transforms, state management.

**Integration**: API clients (mock servers), navigation flows, state persistence, notification handling.

**E2E (Maestro)**:

```yaml
appId: com.example.myapp
---
- launchApp: { clearState: true }
- assertVisible: "Welcome"
- tapOn: "Get Started"
- assertVisible: "You're all set"
- tapOn: "Start Using App"
- assertVisible: "Home"
```

**AI-Driven (agent-device)**:

```bash
agent-device open "My App" --platform ios   # Open app
agent-device snapshot                        # Accessibility tree
agent-device click @e3                       # Interact via refs
agent-device screenshot ./evidence.png       # Capture state
```

**Visual**: Screenshots at key states via `ios-simulator-mcp` or `agent-device`. Test light/dark modes across: iPhone SE, iPhone 16, iPhone 16 Pro Max, iPad.

**Accessibility**: `agent-device snapshot` — inspect tree. Verify labels, VoiceOver/TalkBack, colour contrast, Dynamic Type. See `tools/accessibility/accessibility-audit.md`.

**Performance**: Launch < 2s, animations 60fps. Monitor memory and network payload. Test on older devices.

## Device Matrix

| Device | Screen | Purpose |
|--------|--------|---------|
| iPhone SE (3rd) | 4.7" | Smallest |
| iPhone 16 | 6.1" | Standard |
| iPhone 16 Pro Max | 6.9" | Largest |
| iPad (10th) | 10.9" | Tablet |
| Pixel 7 / Galaxy S24 | 6.2-6.3" | Android |

Use `playwright-emulation` device presets for web-based testing.

## Distribution Testing

**iOS (TestFlight)**: `eas build --platform ios --profile preview` or Xcode archive → App Store Connect. Internal: 100 testers, no review. External: 10k testers, review required.

**Android**: `eas build --platform android --profile preview` or `./gradlew assembleRelease` → Google Play Console internal track. Distribute via email/Google Group.

## Pre-Submission Checklist

- [ ] E2E flows pass on latest OS versions
- [ ] No crashes in crash reporting
- [ ] Accessibility audit passes
- [ ] Light/dark modes work
- [ ] Localisation complete (or English-only intentional)
- [ ] Offline behaviour graceful
- [ ] Deep links, push notifications work
- [ ] In-app purchases complete (sandbox)
- [ ] App icon, splash screen correct
- [ ] No placeholder/test data visible

## Related

- `tools/mobile/agent-device.md` — AI-driven device automation
- `tools/mobile/xcodebuild-mcp.md` — Xcode build/test
- `tools/mobile/maestro.md` — E2E test flows
- `tools/mobile/ios-simulator-mcp.md` — simulator interaction
- `tools/browser/playwright-emulation.md` — mobile web testing
- `tools/accessibility/accessibility-audit.md` — accessibility
