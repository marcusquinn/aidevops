---
description: Swift/SwiftUI native iOS app development - Xcode project setup, SwiftUI patterns, native APIs
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
  context7_*: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Swift Development - Native iOS Apps

<!-- AI-CONTEXT-START -->

## Quick Reference

- **IDE**: Xcode — use `xcodebuild-mcp` for AI-driven build/test
- **Docs**: Context7 MCP for latest Swift/SwiftUI docs
- **Min target**: iOS 17+ | **Architecture**: MVVM + Swift Concurrency (async/await)
- **Scaffold**: `xcodebuild-mcp scaffold_ios_project`
- **Choose Swift over Expo when**: deep Apple ecosystem (HealthKit, HomeKit, Siri, Widgets), max native performance (games, AR), Watch/tvOS/visionOS targets, WebKit hybrid content, Swift-specific libraries

<!-- AI-CONTEXT-END -->

## Project Structure

```text
MyApp/
├── MyApp.swift              # @main entry point
├── ContentView.swift        # Root view
├── Info.plist, Assets.xcassets/
├── Models/                  # Data models
├── Views/                   # SwiftUI views + Components/
├── Services/                # API clients, auth, notifications
├── Stores/                  # State management (@Observable)
├── Extensions/              # Color+Theme, View+Modifiers
├── Resources/               # Fonts, Localizable.xcstrings
└── Tests/                   # UnitTests/, UITests/
```

## Development Standards

### SwiftUI Patterns

**MVVM with `@Observable`** — keep views <100 lines. ViewModel pattern:

```swift
@Observable final class HomeViewModel {
    var items: [Item] = []
    var isLoading = false
    var errorMessage: String?
    func loadItems() async {
        isLoading = true; defer { isLoading = false }
        do { items = try await APIService.shared.fetchItems() }
        catch { errorMessage = error.localizedDescription }
    }
}
```

### Design System

Semantic color/font tokens in `Extensions/Color+Theme.swift` and `Font+Theme.swift`. Use `Color("Primary")` asset catalog names, `Font.system(.title, design: .rounded, weight: .bold)`.

### Animations

`withAnimation(.spring())` | `.matchedGeometryEffect` | `.transition()` | `TimelineView` | `sensoryFeedback()` (haptics)

### Native Capabilities

| Feature | Framework | Notes |
|---------|-----------|-------|
| Health data | HealthKit | Step count, heart rate, sleep |
| Home automation | HomeKit | Smart home device control |
| Siri | SiriKit / App Intents | Voice commands, shortcuts |
| Widgets | WidgetKit | Home screen and Lock Screen widgets |
| Live Activities | ActivityKit | Dynamic Island, Lock Screen updates |
| AR | ARKit + RealityKit | Augmented reality |
| ML | Core ML + Create ML | On-device machine learning |
| Maps | MapKit | Native Apple Maps |
| Payments | StoreKit 2 | In-app purchases (or RevenueCat) |
| Notifications | UserNotifications | Push and local |
| Biometrics | LocalAuthentication | Face ID, Touch ID |
| Camera | AVFoundation | Photo/video capture |
| NFC | Core NFC | NFC tag reading |
| Web content | WebKit for SwiftUI | Native WebView, JS bridge, custom URL schemes (iOS 26+) |

### Swift Concurrency

`async/await` | `Task` groups (parallel) | `@MainActor` (UI) | `AsyncStream` (sensors, location) | `Sendable` (thread safety)

### Data Persistence

`@AppStorage` (prefs) | SwiftData (structured, replaces Core Data) | Keychain (secure creds) | FileManager (docs/cache) | CloudKit (iCloud sync)

## Hybrid Content (WebKit for SwiftUI)

> iOS 26+ / macOS 26+ / visionOS 26+. `import WebKit`. Source: WWDC 2025 Session 231. Guard with `#available` for earlier targets.

`WebPage` (`@Observable`): `url`, `title`, `isLoading`, `estimatedProgress`, `themeColor`, `isAtTop`, `isAtBottom`.

```swift
// Basic usage
@State private var page = WebPage()
WebView(page)
    .onAppear { page.url = URL(string: "https://example.com") }
    .navigationTitle(page.title ?? "Loading...")

// JS bridge — typed args/results auto-bridged
let count: Int = try await page.callJavaScript("addItems",
    arguments: ["items": ["apple", "banana"], "startIndex": 0])

// Custom URL schemes — serve bundled assets (no network)
WebView(page).urlScheme("app-resource") { request in
    guard let path = request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
          let url = Bundle.main.resourceURL?.appendingPathComponent(path),
          let data = try? Data(contentsOf: url) else {
        return .init(statusCode: 404, headerFields: [:], data: Data())
    }
    return .init(statusCode: 200, headerFields: [:], data: data)
}

// Navigation policy
page.navigationDeciding = .handler { action in
    action.request.url?.host == "example.com" ? .allow : .cancel
}
```

**Modifiers**: `webViewScrollPosition(_:)`, `onScrollGeometryChange`, `findNavigator(isPresented:)`, `webViewScrollInputBehavior(_:for:)`

## Build, Test & Distribution

```text
# XcodeBuildMCP
discover_projs | build_sim --scheme MyApp | test_sim --scheme MyApp
build_run_sim --scheme MyApp | screenshot
```

```bash
# Local Xcode
xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
xcodebuild test -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
xcodebuild archive -scheme MyApp -archivePath MyApp.xcarchive
```

**TestFlight**: Configure auto-signing → Archive (`Product > Archive`) → upload via Organizer → add testers in App Store Connect (external requires App Review). Use `xcodebuild-mcp` for direct device deployment.

## Related

- `tools/mobile/app-dev/expo.md` - Expo alternative for cross-platform
- `tools/mobile/app-dev/testing.md` - Full testing guide
- `tools/mobile/app-dev/publishing.md` - App Store submission
- `tools/mobile/xcodebuild-mcp.md` - Xcode build integration
