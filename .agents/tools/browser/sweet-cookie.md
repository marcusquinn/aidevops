---
description: Browser cookie extraction for automation and session reuse
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Sweet Cookie - Browser Cookie Extraction

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract browser cookies for automation, session reuse, and authenticated scraping
- **Two Libraries**: TypeScript (cross-platform) and Swift (macOS native)
- **Use Case**: When you need real browser session cookies for API calls or automation

**When to Use Sweet Cookie**:
- Reusing existing browser sessions (already logged in)
- Authenticated API calls without re-login
- Bypassing automation detection with real cookies
- CI/CD pipelines needing browser auth state

**When NOT to Use**:
- Fresh browser automation (use agent-browser, stagehand)
- Sites with app-bound encryption (use Chrome extension)
- Simple scraping without auth (use crawl4ai)

**Quick Decision**:

```text
Need cookies from existing browser session?
    |
    +-> TypeScript/Node.js project? --> @steipete/sweet-cookie
    |
    +-> Swift/macOS native app? --> SweetCookieKit
    |
    +-> App-bound cookies (Chrome 127+)? --> Use Chrome extension
```
<!-- AI-CONTEXT-END -->

## Overview

Sweet Cookie provides two complementary libraries for extracting browser cookies:

| Library | Language | Platforms | Best For |
|---------|----------|-----------|----------|
| `@steipete/sweet-cookie` | TypeScript | macOS, Windows, Linux | Node.js/Bun automation, CI/CD |
| `SweetCookieKit` | Swift | macOS only | Native macOS apps, Swift tooling |

Both libraries read cookies directly from browser profile databases, avoiding the need for manual cookie export or browser extensions in most cases.

## @steipete/sweet-cookie (TypeScript)

Cross-platform cookie extraction for Node.js and Bun.

### Installation

```bash
npm install @steipete/sweet-cookie
# or
pnpm add @steipete/sweet-cookie
# or
bun add @steipete/sweet-cookie
```

**Requirements**: Node.js >= 22 (for `node:sqlite`) or Bun (for `bun:sqlite`)

### Basic Usage

```typescript
import { getCookies, toCookieHeader } from '@steipete/sweet-cookie';

// Extract cookies for a URL
const { cookies, warnings } = await getCookies({
  url: 'https://example.com/',
  names: ['session', 'csrf'],
  browsers: ['chrome', 'edge', 'firefox', 'safari'],
});

// Log any warnings (e.g., browser locked, keychain prompt)
for (const warning of warnings) console.warn(warning);

// Convert to Cookie header string
const cookieHeader = toCookieHeader(cookies, { dedupeByName: true });

// Use in fetch request
const response = await fetch('https://api.example.com/data', {
  headers: { Cookie: cookieHeader }
});
```

### Multiple Origins (OAuth/SSO)

```typescript
// Handle OAuth redirects across domains
const { cookies } = await getCookies({
  url: 'https://app.example.com/',
  origins: ['https://accounts.example.com/', 'https://login.example.com/'],
  names: ['session', 'xsrf'],
  browsers: ['chrome'],
  mode: 'merge',
});
```

### Specific Browser Profile

```typescript
// Chrome with specific profile
await getCookies({
  url: 'https://example.com/',
  browsers: ['chrome'],
  chromeProfile: 'Default', // or full path to Cookies DB
});

// Edge with specific profile
await getCookies({
  url: 'https://example.com/',
  browsers: ['edge'],
  edgeProfile: 'Profile 1',
});
```

### Inline Cookies (CI/CD)

For environments where browser DB access isn't possible:

```typescript
// From file (exported via Chrome extension)
await getCookies({
  url: 'https://example.com/',
  browsers: ['chrome'],
  inlineCookiesFile: '/path/to/cookies.json',
});

// From JSON string
await getCookies({
  url: 'https://example.com/',
  inlineCookiesJson: '{"cookies": [...]}',
});

// From base64
await getCookies({
  url: 'https://example.com/',
  inlineCookiesBase64: 'eyJjb29raWVzIjogWy4uLl19',
});
```

### Environment Variables

```bash
# Browser selection
SWEET_COOKIE_BROWSERS=chrome,safari,firefox
SWEET_COOKIE_MODE=merge  # or 'first'

# Profile selection
SWEET_COOKIE_CHROME_PROFILE=Default
SWEET_COOKIE_EDGE_PROFILE=Default
SWEET_COOKIE_FIREFOX_PROFILE=default-release

# Linux keyring (if needed)
SWEET_COOKIE_LINUX_KEYRING=gnome  # or kwallet, basic
SWEET_COOKIE_CHROME_SAFE_STORAGE_PASSWORD=...
```

### Supported Browsers

| Browser | macOS | Windows | Linux |
|---------|-------|---------|-------|
| Chrome | Yes | Yes | Yes |
| Edge | Yes | Yes | Yes |
| Firefox | Yes | Yes | Yes |
| Safari | Yes | - | - |

### Chrome Extension (App-Bound Cookies)

For Chrome 127+ with app-bound encryption, use the included Chrome extension:

1. Install from `apps/extension` in the sweet-cookie repo
2. Export cookies as JSON/base64/file
3. Use `inlineCookiesFile` or `inlineCookiesJson` option

## SweetCookieKit (Swift)

Native macOS cookie extraction for Swift applications.

### Installation

```swift
// Package.swift
.package(url: "https://github.com/steipete/SweetCookieKit.git", from: "0.2.0")
```

**Requirements**: macOS 13+, Swift 6

### Basic Usage

```swift
import SweetCookieKit

let client = BrowserCookieClient()

// List available browser profiles
let stores = client.stores(for: .chrome)

// Get cookies from specific profile
let store = stores.first { $0.profile.name == "Default" }
let query = BrowserCookieQuery(domains: ["example.com"])
let records = try client.records(matching: query, in: store!)

// Convert to HTTPCookie
let cookies = try client.cookies(matching: query, in: store!)
```

### Query Options

```swift
let query = BrowserCookieQuery(
    domains: ["example.com"],
    domainMatch: .suffix,      // Match subdomains
    includeExpired: false
)
```

### Browser Import Order

```swift
// Try all supported browsers in order
let order = Browser.defaultImportOrder
for browser in order {
    let results = try client.records(matching: query, in: browser)
    // Results grouped by profile/store
}
```

### Chromium Local Storage

```swift
// Read localStorage entries
let entries = ChromiumLocalStorageReader.readEntries(
    for: "https://example.com",
    in: levelDBURL
)
```

### Chromium LevelDB Helpers

```swift
// Raw text entries
let entries = ChromiumLevelDBReader.readTextEntries(in: levelDBURL)

// Token candidates (for auth tokens)
let tokens = ChromiumLevelDBReader.readTokenCandidates(
    in: levelDBURL,
    minimumLength: 80
)
```

### CLI Tool

```bash
cd Examples/CookieCLI
swift run SweetCookieCLI --help

# List stores
swift run SweetCookieCLI stores

# Export cookies as JSON
swift run SweetCookieCLI export --domain example.com --format json
```

## Comparison: When to Use Each

| Scenario | Recommended Tool |
|----------|------------------|
| Node.js/Bun automation | `@steipete/sweet-cookie` |
| Swift/macOS native app | `SweetCookieKit` |
| CI/CD pipeline | `@steipete/sweet-cookie` + inline cookies |
| Cross-platform script | `@steipete/sweet-cookie` |
| macOS-only CLI tool | Either (Swift for native, TS for npm ecosystem) |
| Browser extension needed | `@steipete/sweet-cookie` Chrome extension |

## Integration with aidevops

### With Bird (X/Twitter CLI)

Bird uses sweet-cookie for automatic authentication:

```bash
# Bird auto-extracts X/Twitter cookies
bird whoami  # Shows logged-in account
bird tweet "Hello from CLI"
```

### With Browser Automation

Combine with agent-browser or stagehand for authenticated sessions:

```typescript
import { getCookies, toCookieHeader } from '@steipete/sweet-cookie';

// Get existing session cookies
const { cookies } = await getCookies({
  url: 'https://app.example.com/',
  browsers: ['chrome'],
});

// Inject into automation
const cookieHeader = toCookieHeader(cookies);
// Use with fetch, playwright, or other tools
```

### With Crawl4AI

For authenticated crawling:

```bash
# Export cookies to file
# Then use with crawl4ai
crawl4ai https://app.example.com --cookies /path/to/cookies.json
```

## Security Notes

- **Keychain prompts**: Chrome/Edge may trigger Keychain access prompts on macOS
- **Full Disk Access**: Safari requires Full Disk Access permission
- **Browser must be closed**: Some browsers lock their cookie DB while running
- **Encrypted cookies**: Chromium cookies are encrypted; sweet-cookie handles decryption via OS keychain

### Keychain Prompt Handler (Swift)

```swift
import SweetCookieKit

// Show custom UI before system keychain prompt
BrowserCookieKeychainPromptHandler.shared.handler = { context in
    // context.kind = .chromiumSafeStorage
    // Show blocking alert or custom UI
}
```

## Resources

- **sweet-cookie (TypeScript)**: https://github.com/steipete/sweet-cookie
- **SweetCookieKit (Swift)**: https://github.com/steipete/SweetCookieKit
- **Documentation**: https://sweetcookie.dev
- **Chrome Extension**: `apps/extension` in sweet-cookie repo

## Related Tools

- `tools/browser/agent-browser.md` - CLI browser automation (default)
- `tools/browser/stagehand.md` - AI-powered browser automation
- `tools/browser/playwriter.md` - Chrome extension MCP for existing sessions
- `tools/social-media/bird.md` - X/Twitter CLI (uses sweet-cookie)
