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

# MiniSim - iOS and Android Emulator Launcher

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: macOS menu bar app for launching iOS simulators and Android emulators
- **Install**: `brew install --cask minisim`
- **Global Shortcut**: Option + Shift + E
- **Requirements**: Xcode (iOS) and/or Android Studio (Android)
- **Website**: https://www.minisim.app/
- **GitHub**: https://github.com/okwasniewski/MiniSim

**Key Features**:
- Launch iOS simulators and Android emulators from menu bar
- Copy device UDID/ADB ID
- Cold boot Android emulators
- Run Android emulators without audio (saves Bluetooth headphone battery)
- Toggle accessibility on Android emulators
- Focus running devices via accessibility API
- Set default launch flags

**Why MiniSim**: Native Swift/AppKit app - lightweight, fast, no Electron overhead

<!-- AI-CONTEXT-END -->

## Installation

```bash
# Install via Homebrew (recommended)
brew install --cask minisim

# Or download from GitHub releases
# https://github.com/okwasniewski/MiniSim/releases
```

## Requirements

MiniSim uses `xcrun` and Android SDK's `emulator` command to discover devices:

- **iOS Simulators**: Requires Xcode with iOS Simulator installed
- **Android Emulators**: Requires Android Studio with emulator configured

## Usage

### Global Shortcut

Press **Option + Shift + E** to open the MiniSim menu from anywhere.

### iOS Simulator Features

| Action | Description |
|--------|-------------|
| Launch | Click simulator name to boot |
| Copy UDID | Right-click > Copy UDID |
| Copy Name | Right-click > Copy Name |
| Delete | Right-click > Delete Simulator |

### Android Emulator Features

| Action | Description |
|--------|-------------|
| Launch | Click emulator name to boot |
| Cold Boot | Right-click > Cold Boot |
| No Audio | Right-click > Launch without audio |
| Toggle A11y | Right-click > Toggle Accessibility |
| Copy ADB ID | Right-click > Copy ADB ID |
| Copy Name | Right-click > Copy Name |

### Default Launch Flags

Configure default flags in MiniSim preferences:

- **Android**: Add flags like `-no-audio`, `-no-boot-anim`
- **iOS**: Configure simulator options

## Integration with AI Workflows

### Launching Simulators from Scripts

```bash
# List iOS simulators
xcrun simctl list devices

# Boot specific iOS simulator
xcrun simctl boot "iPhone 15 Pro"

# List Android emulators
emulator -list-avds

# Launch Android emulator
emulator -avd Pixel_7_API_34

# Launch without audio (saves Bluetooth battery)
emulator -avd Pixel_7_API_34 -no-audio
```

### Raycast Extension

MiniSim has a Raycast extension for keyboard-driven workflows:

1. Install Raycast: https://www.raycast.com
2. Install MiniSim extension from Raycast Store
3. Use Raycast to search and launch emulators

## Troubleshooting

### Simulators Not Showing

1. Verify Xcode is installed: `xcode-select -p`
2. Check simulators exist: `xcrun simctl list devices`
3. Restart MiniSim after installing new simulators

### Android Emulators Not Showing

1. Verify Android SDK path is configured
2. Check emulators exist: `emulator -list-avds`
3. Ensure `ANDROID_HOME` or `ANDROID_SDK_ROOT` is set

### Permission Issues

MiniSim may need accessibility permissions to focus devices:

1. Open System Preferences > Security & Privacy > Privacy
2. Select Accessibility
3. Add MiniSim to the list

## Related Tools

- `tools/browser/stagehand.md` - Browser automation (web testing)
- `tools/browser/playwright.md` - Cross-browser testing
- `services/hosting/localhost.md` - Local development setup
