---
description: MiniSim - macOS menu bar app for iOS/Android emulator management
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# MiniSim - iOS and Android Emulator Launcher

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: macOS menu bar app for launching iOS simulators and Android emulators
- **Install**: `brew install --cask minisim`
- **Global Shortcut**: Option + Shift + E
- **Requirements**: Xcode (iOS) and/or Android Studio (Android)
- **Website**: https://www.minisim.app/
- **GitHub**: https://github.com/okwasniewski/MiniSim
- **Why MiniSim**: Native Swift/AppKit — lightweight, fast, no Electron overhead

**Menu bar actions** (right-click device name):

| Platform | Actions |
|----------|---------|
| iOS | Launch, Copy UDID, Copy Name, Delete Simulator |
| Android | Launch, Cold Boot, No Audio, Toggle A11y, Copy ADB ID, Copy Name |

**Default launch flags**: Configure in MiniSim preferences (`-no-audio`, `-no-boot-anim` for Android).

<!-- AI-CONTEXT-END -->

## CLI Commands

```bash
# iOS simulators
xcrun simctl list devices          # List
xcrun simctl boot "iPhone 15 Pro"  # Boot

# Android emulators
emulator -list-avds                       # List
emulator -avd Pixel_7_API_34             # Launch
emulator -avd Pixel_7_API_34 -no-audio   # Launch without audio (saves Bluetooth battery)
```

MiniSim uses `xcrun` and Android SDK's `emulator` command to discover devices.

## Raycast Integration

Install the MiniSim extension from the Raycast Store for keyboard-driven emulator launching.

## Troubleshooting

**iOS simulators not showing:**

1. Verify Xcode: `xcode-select -p`
2. Check simulators: `xcrun simctl list devices`
3. Restart MiniSim after installing new simulators

**Android emulators not showing:**

1. Verify SDK path and `ANDROID_HOME` / `ANDROID_SDK_ROOT` is set
2. Check emulators: `emulator -list-avds`

**Accessibility permissions** (needed to focus devices): System Preferences > Security & Privacy > Privacy > Accessibility > add MiniSim.

## Related Tools

- `tools/browser/stagehand.md` - Browser automation (web testing)
- `tools/browser/playwright.md` - Cross-browser testing
- `services/hosting/localhost.md` - Local development setup
