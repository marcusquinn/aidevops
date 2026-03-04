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

- **Purpose**: Build native iOS apps with Swift and SwiftUI
- **IDE**: Xcode (use `xcodebuild-mcp` for AI-driven build/test)
- **Docs**: Use Context7 MCP for latest Swift and SwiftUI documentation
- **Min target**: iOS 17+ (for latest SwiftUI features)
- **Architecture**: MVVM with SwiftUI, Swift Concurrency (async/await)

**When to choose Swift over Expo**:

- Deep Apple ecosystem integration (HealthKit, HomeKit, Siri Intents, Widgets)
- Maximum native performance (games, AR, complex animations)
- Apple Watch, tvOS, or visionOS targets
- Hybrid native + web content apps (WebKit for SwiftUI provides first-class WebView support)
- Leveraging Swift-specific libraries

**Project scaffold via XcodeBuildMCP**:

```text
Use xcodebuild-mcp scaffold_ios_project to create a new project
```

<!-- AI-CONTEXT-END -->

## Project Structure

```text
MyApp/
├── MyApp.swift              # App entry point (@main)
├── ContentView.swift        # Root view
├── Info.plist               # App configuration
├── Assets.xcassets/         # Images, colours, app icon
├── Models/                  # Data models
│   ├── User.swift
│   └── AppState.swift
├── Views/                   # SwiftUI views
│   ├── Home/
│   │   ├── HomeView.swift
│   │   └── HomeViewModel.swift
│   ├── Onboarding/
│   │   ├── OnboardingView.swift
│   │   └── OnboardingStep.swift
│   ├── Settings/
│   │   └── SettingsView.swift
│   └── Components/          # Reusable UI components
│       ├── PrimaryButton.swift
│       └── CardView.swift
├── Services/                # Business logic, API clients
│   ├── APIService.swift
│   ├── AuthService.swift
│   └── NotificationService.swift
├── Stores/                  # State management
│   └── AppStore.swift
├── Extensions/              # Swift extensions
│   ├── Color+Theme.swift
│   └── View+Modifiers.swift
├── Resources/               # Fonts, localisation
│   └── Localizable.xcstrings
└── Tests/
    ├── UnitTests/
    └── UITests/
```

## Development Standards

### SwiftUI Patterns

**MVVM with Observable**:

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

**View composition**: Break views into small, focused components. Each view file should be under 100 lines.

### Design System

Define a theme that matches the app's brand:

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

SwiftUI provides excellent built-in animation support:

- `withAnimation(.spring())` for natural transitions
- `.matchedGeometryEffect` for shared element transitions
- `.transition()` for view enter/exit
- `TimelineView` for continuous animations
- `sensoryFeedback()` modifier for haptics paired with animations

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

Use structured concurrency throughout:

- `async/await` for all asynchronous operations
- `Task` groups for parallel work
- `@MainActor` for UI updates
- `AsyncStream` for continuous data (sensors, location)
- `Sendable` conformance for thread safety

### Data Persistence

| Approach | Use Case |
|----------|----------|
| `@AppStorage` | Simple user preferences |
| SwiftData | Structured local data (replaces Core Data) |
| Keychain | Secure credentials and tokens |
| FileManager | Documents, cached files |
| CloudKit | iCloud sync across devices |

## Hybrid Content (WebKit for SwiftUI)

> iOS 26+ / macOS 26+ / visionOS 26+. Requires `import WebKit`.
> Source: WWDC 2025 Session 231 — "Meet WebKit for SwiftUI".

First-class SwiftUI views for embedding web content — replaces the old `WKWebView` UIKit/AppKit bridge pattern.

### WebView and WebPage

```swift
import WebKit

struct ArticleView: View {
    @State private var page = WebPage()

    var body: some View {
        WebView(page)
            .onAppear { page.url = URL(string: "https://example.com/article")! }
            .navigationTitle(page.title ?? "Loading...")
    }
}
```

`WebPage` is an `@Observable` class exposing: `url`, `title`, `isLoading`, `estimatedProgress`, `themeColor`, `isAtTop`, `isAtBottom`.

### JavaScript Bridge

Call JavaScript with typed argument dictionaries and get typed results:

```swift
let count: Int = try await page.callJavaScript(
    "addItems",
    arguments: ["items": ["apple", "banana"], "startIndex": 0]
)
```

Arguments and return values are automatically bridged between Swift and JavaScript types.

### Custom URL Schemes

Serve bundled HTML/CSS/JS via custom URL schemes using `URLSchemeHandler`:

```swift
WebView(page)
    .urlScheme("app-resource") { request in
        let path = Bundle.main.path(forResource: request.url!.path, ofType: nil)!
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        return .init(statusCode: 200, headerFields: [:], data: data)
    }
```

Load with `app-resource:///index.html` — content stays local, no network requests.

### Navigation Policy

Control which navigations are allowed using `WebPage.NavigationDeciding`:

```swift
page.navigationDeciding = .handler { action in
    if action.request.url?.host == "example.com" {
        return .allow
    }
    return .cancel
}
```

### View Modifiers

| Modifier | Purpose |
|----------|---------|
| `webViewScrollPosition(_:)` | Bind scroll position |
| `onScrollGeometryChange` | React to scroll geometry changes |
| `findNavigator(isPresented:)` | In-page find (Cmd+F) |
| `webViewScrollInputBehavior(_:for:)` | Control scroll input handling |

## Build and Test

### Using XcodeBuildMCP

```text
# Discover project
discover_projs

# Build for simulator
build_sim --scheme MyApp

# Run tests
test_sim --scheme MyApp

# Build and run
build_run_sim --scheme MyApp

# Screenshot current state
screenshot
```

### Local Xcode Commands

```bash
# Build
xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

# Test
xcodebuild test -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

# Archive for distribution
xcodebuild archive -scheme MyApp -archivePath MyApp.xcarchive
```

## TestFlight Setup

1. Configure signing in Xcode (Automatically manage signing)
2. Archive the app (`Product > Archive`)
3. Upload to App Store Connect via Xcode Organizer
4. Add internal testers in App Store Connect
5. External testing requires App Review approval

Or use `xcodebuild-mcp` device tools for direct device deployment during development.

## Related

- `mobile-app-dev/expo.md` - Expo alternative for cross-platform
- `mobile-app-dev/testing.md` - Full testing guide
- `mobile-app-dev/publishing.md` - App Store submission
- `tools/mobile/xcodebuild-mcp.md` - Xcode build integration
