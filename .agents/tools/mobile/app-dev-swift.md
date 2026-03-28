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
├── Views/                   # SwiftUI views
│   ├── Home/                # HomeView + HomeViewModel
│   ├── Onboarding/          # OnboardingView + OnboardingStep
│   ├── Settings/
│   └── Components/          # Reusable UI (PrimaryButton, CardView)
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

```swift
extension Color {
    static let appPrimary = Color("Primary")
    static let appBackground = Color("Background")
    static let appSurface = Color("Surface")
    static let appText = Color("Text")
    static let appTextSecondary = Color("TextSecondary")
}

extension Font {
    static let appTitle = Font.system(.title, design: .rounded, weight: .bold)
    static let appBody = Font.system(.body, design: .default)
    static let appCaption = Font.system(.caption, design: .default)
}
```

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

Replaces `WKWebView` UIKit/AppKit bridge. Guard with `#available` for earlier targets:

```swift
var body: some View {
    if #available(iOS 26.0, *) {
        WebView(url: url)
    } else {
        LegacyWKWebView(url: url) // UIViewRepresentable wrapper around WKWebView
    }
}
```

### WebView and WebPage

```swift
import WebKit

struct ArticleView: View {
    @State private var page = WebPage()

    var body: some View {
        WebView(page)
            .onAppear {
                guard let url = URL(string: "https://example.com/article") else { return }
                page.url = url
            }
            .navigationTitle(page.title ?? "Loading...")
    }
}
```

`WebPage` is `@Observable`: `url`, `title`, `isLoading`, `estimatedProgress`, `themeColor`, `isAtTop`, `isAtBottom`.

### JavaScript Bridge

Typed args, typed results — automatically bridged between Swift and JS:

```swift
let count: Int = try await page.callJavaScript(
    "addItems",
    arguments: ["items": ["apple", "banana"], "startIndex": 0]
)
```

### Custom URL Schemes

Serve bundled HTML/CSS/JS via `URLSchemeHandler` — load with `app-resource:///index.html`, no network requests:

```swift
WebView(page)
    .urlScheme("app-resource") { request in
        guard let url = request.url, !url.path.isEmpty else {
            return .init(statusCode: 400, headerFields: [:], data: Data())
        }
        let relativePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let fileURL = Bundle.main.resourceURL?.appendingPathComponent(relativePath) else {
            return .init(statusCode: 404, headerFields: [:], data: Data())
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return .init(statusCode: 200, headerFields: [:], data: data)
        } catch {
            return .init(statusCode: 404, headerFields: [:], data: Data())
        }
    }
```

### Navigation Policy

Control navigations via `WebPage.NavigationDeciding`:

```swift
page.navigationDeciding = .handler { action in
    if action.request.url?.host == "example.com" { return .allow }
    return .cancel
}
```

### WebView Modifiers

| Modifier | Purpose |
|----------|---------|
| `webViewScrollPosition(_:)` | Bind scroll position |
| `onScrollGeometryChange` | React to scroll geometry changes |
| `findNavigator(isPresented:)` | In-page find (Cmd+F) |
| `webViewScrollInputBehavior(_:for:)` | Control scroll input handling |

## Build and Test

### XcodeBuildMCP

```text
discover_projs                   # Discover project
build_sim --scheme MyApp         # Build for simulator
test_sim --scheme MyApp          # Run tests
build_run_sim --scheme MyApp     # Build and run
screenshot                       # Screenshot current state
```

### Local Xcode Commands

```bash
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
