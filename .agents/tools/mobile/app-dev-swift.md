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
├── Info.plist
├── Assets.xcassets/
├── Models/                  # Data models (User, AppState)
├── Views/                   # SwiftUI views (HomeView, OnboardingView, Components/)
├── Services/                # API clients, auth, notifications
├── Stores/                  # State management (AppStore)
├── Extensions/              # Color+Theme, View+Modifiers
├── Resources/               # Fonts, Localizable.xcstrings
└── Tests/                   # UnitTests/, UITests/
```

## Development Standards

### SwiftUI Patterns

**MVVM with `@Observable`** — keep views <100 lines per file:

```swift
@Observable
final class HomeViewModel {
    var items: [Item] = []
    var isLoading = false
    var errorMessage: String?

    func loadItems() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await APIService.shared.fetchItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

### Design System

Define semantic color/font tokens in `Extensions/Color+Theme.swift` and `Extensions/Font+Theme.swift` using `Color("Primary")` asset catalog names. Use `Font.system(.title, design: .rounded, weight: .bold)` patterns.

### Animations

- `withAnimation(.spring())` — natural transitions
- `.matchedGeometryEffect` — shared element transitions
- `.transition()` — view enter/exit
- `TimelineView` — continuous animations
- `sensoryFeedback()` — haptics paired with animations

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

- `async/await` — all async operations
- `Task` groups — parallel work
- `@MainActor` — UI updates
- `AsyncStream` — continuous data (sensors, location)
- `Sendable` — thread safety conformance

### Data Persistence

| Approach | Use Case |
|----------|----------|
| `@AppStorage` | Simple user preferences |
| SwiftData | Structured local data (replaces Core Data) |
| Keychain | Secure credentials and tokens |
| FileManager | Documents, cached files |
| CloudKit | iCloud sync across devices |

## Hybrid Content (WebKit for SwiftUI)

> iOS 26+ / macOS 26+ / visionOS 26+. Requires `import WebKit`. Source: WWDC 2025 Session 231.

Replaces `WKWebView` UIKit/AppKit bridge. Guard with `#available` for earlier targets.

**`WebPage`** is `@Observable`: `url`, `title`, `isLoading`, `estimatedProgress`, `themeColor`, `isAtTop`, `isAtBottom`.

```swift
struct ArticleView: View {
    @State private var page = WebPage()
    var body: some View {
        WebView(page)
            .onAppear { page.url = URL(string: "https://example.com/article") }
            .navigationTitle(page.title ?? "Loading...")
    }
}
```

**JavaScript bridge** — typed args/results automatically bridged between Swift and JS:

```swift
let count: Int = try await page.callJavaScript("addItems",
    arguments: ["items": ["apple", "banana"], "startIndex": 0])
```

**Custom URL schemes** — serve bundled HTML/CSS/JS via `URLSchemeHandler` (no network requests):

```swift
WebView(page)
    .urlScheme("app-resource") { request in
        guard let path = request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let fileURL = Bundle.main.resourceURL?.appendingPathComponent(path) else {
            return .init(statusCode: 404, headerFields: [:], data: Data())
        }
        return (try? .init(statusCode: 200, headerFields: [:], data: Data(contentsOf: fileURL)))
            ?? .init(statusCode: 404, headerFields: [:], data: Data())
    }
```

**Navigation policy** — control via `WebPage.NavigationDeciding`:

```swift
page.navigationDeciding = .handler { action in
    action.request.url?.host == "example.com" ? .allow : .cancel
}
```

**WebView modifiers**: `webViewScrollPosition(_:)`, `onScrollGeometryChange`, `findNavigator(isPresented:)`, `webViewScrollInputBehavior(_:for:)`

## Build and Test

```text
# XcodeBuildMCP
discover_projs                   # Discover project
build_sim --scheme MyApp         # Build for simulator
test_sim --scheme MyApp          # Run tests
build_run_sim --scheme MyApp     # Build and run
screenshot                       # Screenshot current state
```

```bash
# Local Xcode
xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
xcodebuild test -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
xcodebuild archive -scheme MyApp -archivePath MyApp.xcarchive  # Distribution
```

## TestFlight

1. Configure signing (Automatically manage signing in Xcode)
2. Archive (`Product > Archive`) and upload via Xcode Organizer
3. Add internal testers in App Store Connect (external requires App Review)

Use `xcodebuild-mcp` device tools for direct device deployment during development.

## Related

- `tools/mobile/app-dev/expo.md` - Expo alternative for cross-platform
- `tools/mobile/app-dev/testing.md` - Full testing guide
- `tools/mobile/app-dev/publishing.md` - App Store submission
- `tools/mobile/xcodebuild-mcp.md` - Xcode build integration
