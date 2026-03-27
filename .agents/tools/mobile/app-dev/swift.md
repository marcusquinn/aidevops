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

- **IDE**: Xcode (use `xcodebuild-mcp` for AI-driven build/test)
- **Docs**: Context7 MCP for latest Swift/SwiftUI documentation
- **Min target**: iOS 17+ (latest SwiftUI features)
- **Architecture**: MVVM with `@Observable`, Swift Concurrency (async/await)

**Choose Swift over Expo when**: deep Apple ecosystem integration (HealthKit, HomeKit, Siri, Widgets), maximum native performance (games, AR, complex animations), Apple Watch/tvOS/visionOS targets, hybrid native+web (WebKit for SwiftUI), or Swift-specific libraries.

**Scaffold**: `xcodebuild-mcp scaffold_ios_project`

<!-- AI-CONTEXT-END -->

## Project Structure

```text
MyApp/
├── MyApp.swift                 # @main entry point
├── ContentView.swift           # Root view
├── Info.plist / Assets.xcassets/
├── Models/                     # Data models, AppState
├── Views/{Feature}/            # FeatureView.swift + FeatureViewModel.swift
│   └── Components/             # Reusable UI
├── Services/                   # API clients, auth, notifications
├── Stores/ / Extensions/ / Resources/
└── Tests/                      # UnitTests/ + UITests/
```

## Development Standards

### MVVM with @Observable

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

Each view file under 100 lines. Define theme via `extension Color { static let appPrimary = Color("Primary") ... }` and `extension Font` for `.appTitle`, `.appBody`, `.appCaption`.

### Animations

`withAnimation(.spring())`, `.matchedGeometryEffect`, `.transition()`, `TimelineView`, `sensoryFeedback()` for haptics.

### Native Capabilities

| Feature | Framework |
|---------|-----------|
| Health | HealthKit |
| Home | HomeKit |
| Siri / Shortcuts | App Intents |
| Widgets / Live Activities | WidgetKit, ActivityKit |
| AR | ARKit + RealityKit |
| ML | Core ML + Create ML |
| Maps | MapKit |
| Payments | StoreKit 2 (or RevenueCat) |
| Push / Local notifications | UserNotifications |
| Biometrics | LocalAuthentication |
| Camera / NFC | AVFoundation, Core NFC |
| Web content (iOS 26+) | WebKit for SwiftUI |

### Swift Concurrency

`async/await` everywhere. `Task` groups for parallel work. `@MainActor` for UI. `AsyncStream` for continuous data. `Sendable` for thread safety.

### Data Persistence

`@AppStorage` (prefs) · SwiftData (structured, replaces Core Data) · Keychain (credentials) · FileManager (docs) · CloudKit (iCloud sync).

## Hybrid Content (WebKit for SwiftUI)

> iOS 26+ / macOS 26+ / visionOS 26+. Requires `import WebKit`.
> Source: WWDC 2025 Session 231 — "Meet WebKit for SwiftUI".

Replaces old `WKWebView` UIKit bridge. For iOS <26, guard with `#available` and fall back to a `UIViewRepresentable` `WKWebView` wrapper.

### Core Pattern

```swift
import WebKit
struct ArticleView: View {
    @State private var page = WebPage()
    var body: some View {
        WebView(page)
            .onAppear { page.url = URL(string: "https://example.com/article") }
            .navigationTitle(page.title ?? "Loading...")
    }
}
```

`WebPage` (`@Observable`): `url`, `title`, `isLoading`, `estimatedProgress`, `themeColor`, `isAtTop`, `isAtBottom`.

### JavaScript Bridge

`let count: Int = try await page.callJavaScript("addItems", arguments: ["items": [...], "startIndex": 0])` — types auto-bridge between Swift and JS.

### Custom URL Schemes

`.urlScheme("app-resource") { request in ... }` serves bundled HTML/CSS/JS via `Bundle.main.resourceURL`. Load with `app-resource:///index.html` — no network requests.

### Navigation Policy

`page.navigationDeciding = .handler { action in action.request.url?.host == "example.com" ? .allow : .cancel }`

### View Modifiers

`webViewScrollPosition(_:)`, `onScrollGeometryChange`, `findNavigator(isPresented:)`, `webViewScrollInputBehavior(_:for:)`.

## Build and Test

**XcodeBuildMCP**: `discover_projs` → `build_sim --scheme MyApp` → `test_sim --scheme MyApp` → `build_run_sim --scheme MyApp` → `screenshot`.

**Local xcodebuild**:

```bash
xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro'       # build
xcodebuild test -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro'   # test
xcodebuild archive -scheme MyApp -archivePath MyApp.xcarchive                            # archive
```

**TestFlight**: Configure auto-signing → Archive → Upload via Organizer → Add testers in App Store Connect (external requires App Review). Or use `xcodebuild-mcp` device tools for dev deployment.

## Related

- `tools/mobile/app-dev/expo.md` - Expo alternative for cross-platform
- `tools/mobile/app-dev/testing.md` - Full testing guide
- `tools/mobile/app-dev/publishing.md` - App Store submission
- `tools/mobile/xcodebuild-mcp.md` - Xcode build integration
