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
  webfetch: false
  task: true
---

# Mobile App Testing - Comprehensive QA

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Test mobile apps across simulators, emulators, and physical devices
- **Tools**: agent-device, xcodebuild-mcp, maestro, ios-simulator-mcp, playwright-emulation
- **Levels**: Unit -> Integration -> E2E -> Visual -> Accessibility -> Performance

**Testing tool decision tree**:

```text
Need AI-driven exploratory testing?
  -> agent-device (CLI, both platforms, ref-based selection)

Need repeatable E2E test flows?
  -> maestro (YAML flows, both platforms, built-in flakiness tolerance)

Need to build/test/deploy iOS apps?
  -> xcodebuild-mcp (MCP, Xcode integration, LLDB debugging)

Need iOS simulator screenshots/interaction?
  -> ios-simulator-mcp (MCP, tap/swipe/type/screenshot)

Need mobile web layout testing?
  -> playwright-emulation (device presets, viewport, touch emulation)
```

<!-- AI-CONTEXT-END -->

## Testing Strategy

### Unit Tests

- **Expo**: Jest + React Native Testing Library
- **Swift**: XCTest (via `xcodebuild-mcp test_sim`)
- Cover business logic, data transformations, state management
- Aim for 80%+ coverage on core logic

### Integration Tests

- Test API client integration with mock servers
- Test navigation flows between screens
- Test state persistence (storage, secure store)
- Test notification handling

### E2E Tests (Maestro)

Create YAML flows for critical user journeys:

```yaml
# flows/onboarding.yaml
appId: com.example.myapp
---
- launchApp:
    clearState: true
- assertVisible: "Welcome"
- tapOn: "Get Started"
- assertVisible: "Step 1"
- tapOn: "Next"
- assertVisible: "Step 2"
- tapOn: "Next"
- assertVisible: "You're all set"
- tapOn: "Start Using App"
- assertVisible: "Home"
```

### AI-Driven Testing (agent-device)

Use agent-device for exploratory testing:

```bash
# Open app on iOS simulator
agent-device open "My App" --platform ios

# Get accessibility tree
agent-device snapshot

# Interact based on refs
agent-device click @e3
agent-device fill @e7 "test@example.com"

# Verify state
agent-device snapshot
agent-device screenshot ./test-evidence.png

# Clean up
agent-device close
```

### Visual Regression

- Capture screenshots at key states using `ios-simulator-mcp` or `agent-device`
- Compare against baseline images
- Test both light and dark modes
- Test across device sizes (iPhone SE, iPhone 16, iPhone 16 Pro Max, iPad)

### Accessibility Testing

- Use `agent-device snapshot` to inspect accessibility tree
- Verify all elements have labels
- Test with VoiceOver (iOS) / TalkBack (Android)
- Check colour contrast ratios
- Verify Dynamic Type support
- See `services/accessibility/accessibility-audit.md`

### Performance Testing

- Monitor app launch time (< 2 seconds target)
- Check memory usage during typical flows
- Profile animation frame rates (60fps target)
- Test on older devices (not just latest hardware)
- Monitor network request count and payload sizes

## Device Matrix

Test on a representative set of devices:

| Device | Screen | Purpose |
|--------|--------|---------|
| iPhone SE (3rd gen) | 4.7" | Smallest supported iPhone |
| iPhone 16 | 6.1" | Standard size |
| iPhone 16 Pro Max | 6.9" | Largest iPhone |
| iPad (10th gen) | 10.9" | Tablet layout |
| Pixel 7 | 6.3" | Standard Android |
| Galaxy S24 | 6.2" | Samsung Android |

Use `playwright-emulation` device presets for web-based testing across these viewports.

## TestFlight and Internal Testing

### iOS (TestFlight)

1. Build with `eas build --platform ios --profile preview` (Expo) or archive in Xcode (Swift)
2. Upload to App Store Connect
3. Add internal testers (up to 100, no review needed)
4. Add external testers (up to 10,000, requires review)
5. Collect feedback via TestFlight's built-in feedback mechanism

### Android (Internal Testing)

1. Build with `eas build --platform android --profile preview` (Expo) or `./gradlew assembleRelease`
2. Upload to Google Play Console
3. Create internal testing track
4. Add testers via email or Google Group
5. Distribute via Play Store internal testing link

## Pre-Submission Checklist

Before submitting to app stores, verify:

- [ ] All E2E flows pass on latest OS versions
- [ ] No crashes in crash reporting (if integrated)
- [ ] Accessibility audit passes
- [ ] Both light and dark modes work correctly
- [ ] All text is localised (or English-only is intentional)
- [ ] App works offline gracefully (if applicable)
- [ ] Deep links work correctly
- [ ] Push notifications arrive and display correctly
- [ ] In-app purchases complete successfully (sandbox testing)
- [ ] App icon displays correctly at all sizes
- [ ] Splash screen displays correctly
- [ ] No placeholder content or test data visible

## Related

- `tools/mobile/agent-device.md` - AI-driven device automation
- `tools/mobile/xcodebuild-mcp.md` - Xcode build/test
- `tools/mobile/maestro.md` - E2E test flows
- `tools/mobile/ios-simulator-mcp.md` - Simulator interaction
- `tools/browser/playwright-emulation.md` - Mobile web testing
- `services/accessibility/accessibility-audit.md` - Accessibility
