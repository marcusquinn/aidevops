---
description: Maestro - painless E2E automation for Android, iOS, and web apps
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# Maestro - E2E Testing for Mobile and Web

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Human-readable YAML-based E2E testing for Android, iOS, and web
- **Install**: `curl -fsSL "https://get.maestro.mobile.dev" | bash`
- **Requirements**: Java 17+ (`java -version` to verify)
- **Docs**: https://docs.maestro.dev
- **GitHub**: https://github.com/mobile-dev-inc/maestro (10.6k stars, Apache-2.0)

**Why Maestro**: Built on learnings from Appium, Espresso, XCTest, and Selenium.
Interpreted YAML flows (no compilation), built-in flakiness tolerance, automatic
waiting. Write your first test in under five minutes.

<!-- AI-CONTEXT-END -->

## Key Commands

| Command | Purpose |
|---------|---------|
| `maestro test flow.yaml` | Run a single test flow |
| `maestro test flows/` | Run all flows in a directory |
| `maestro studio` | Visual test builder (browser-based IDE) |
| `maestro record flow.yaml` | Run flow and record video |
| `maestro hierarchy` | Dump current UI hierarchy (debugging) |

## YAML Flow Syntax

### Core Commands

| Command | Description |
|---------|-------------|
| `launchApp` | Launch app (optional `clearState`, `clearKeychain`) |
| `tapOn` / `doubleTapOn` / `longPressOn` | Tap, double-tap, or long press by text, `id`, or index |
| `inputText` / `eraseText` | Type or remove text in focused field |
| `assertVisible` / `assertNotVisible` | Assert element presence (auto-waits) |
| `scroll` / `scrollUntilVisible` | Scroll screen or until element appears |
| `swipe` | Swipe direction or between coordinates |
| `back` / `hideKeyboard` | Navigate back (Android) or dismiss keyboard |
| `openLink` | Open URL or deep link |
| `takeScreenshot` | Capture screenshot to file |
| `copyTextFrom` / `runScript` | Copy element text or execute JavaScript |
| `runFlow` | Reuse steps from another flow file |
| `setLocation` / `clearState` | Set GPS or wipe app data |
| `repeat` / `retry` | Loop or retry commands |
| `assertWithAI` | AI-powered visual assertions (experimental) |

### Selectors

```yaml
- tapOn: "Submit"                        # By visible text
- tapOn: { id: "submit-btn" }           # By accessibility ID (recommended)
- tapOn: { text: "Item", index: 0 }     # By index when multiple matches
- extendedWaitUntil: { visible: "Done", timeout: 10000 }  # Custom timeout
```

## Cross-Platform Support

| Framework | Notes |
|-----------|-------|
| Native Android | Full (ADB + UIAutomator) |
| Native iOS | Full (XCTest driver, simulator only for CLI) |
| React Native | Use `testID` prop for stable selectors |
| Flutter | Use `semanticsLabel` for selectors |
| Web / Hybrid | Chromium-based, WebView supported |

## Maestro Studio and Cloud

**Studio** (`maestro studio` or standalone desktop app) -- visual IDE for test building:
live device mirror, element inspector, click-to-select YAML generation, AI assistance.
Download: https://maestro.dev/#maestro-studio

**Cloud** -- parallel execution on dedicated infrastructure, up to 90% faster,
deterministic environments. Free trial: https://maestro.dev/cloud

## Common Patterns

```yaml
# Login flow: maestro test -e EMAIL=user@test.com -e PASSWORD=secret flows/login.yaml
appId: com.example.app
---
- launchApp:
    clearState: true
- tapOn: "Sign In"
- tapOn: { id: "email" }
- inputText: "${EMAIL}"
- tapOn: { id: "password" }
- inputText: "${PASSWORD}"
- tapOn: "Log In"
- assertVisible: "Dashboard"
# Navigation
- tapOn: "Settings"
- assertVisible: "Preferences"
- back
- assertVisible: "Dashboard"
- swipe: { direction: LEFT }
# Form validation
- tapOn: "Register"
- tapOn: "Submit"
- assertVisible: "Email is required"
```

## Integration with aidevops Tools

| Tool | Role |
|------|------|
| MiniSim | Boot simulators/emulators before `maestro test` |
| XcodeBuildMCP | Build iOS `.app`, install on simulator, then test |
| iOS Simulator MCP | Manage simulator state alongside Maestro flows |
| Playwright Emulation | Web-based mobile testing (complements native Maestro flows) |
| AXe CLI | Accessibility audits on iOS simulator alongside E2E tests |

Typical workflow: boot simulator (`xcrun simctl boot`), build app (`xcodebuild`), run `maestro test flows/`.

## Related Tools

- `tools/mobile/minisim.md` - Simulator/emulator launcher
- `tools/mobile/xcodebuild-mcp.md` - iOS build and simulator management
- `tools/mobile/ios-simulator-mcp.md` - AI-driven simulator interaction
- `tools/mobile/axe-cli.md` - iOS accessibility testing
- `tools/browser/playwright.md` - Web E2E testing
- `tools/browser/playwright-emulation.md` - Mobile device emulation for web
