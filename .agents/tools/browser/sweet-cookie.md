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
- **Two Libraries**: `@steipete/sweet-cookie` (TypeScript, cross-platform) and `SweetCookieKit` (Swift, macOS)

**When to use**:
- Reusing existing browser sessions (already logged in)
- Authenticated API calls without re-login
- Bypassing automation detection with real cookies
- CI/CD pipelines needing browser auth state

**When NOT to use**:
- Fresh browser automation → use agent-browser, stagehand
- Simple scraping without auth → use crawl4ai

**Decision**:

```text
Need cookies from existing browser session?
    +-> TypeScript/Node.js project? --> @steipete/sweet-cookie
    +-> Swift/macOS native app?     --> SweetCookieKit
    +-> App-bound cookies (Chrome 127+)? --> Chrome extension
```

<!-- AI-CONTEXT-END -->

## @steipete/sweet-cookie (TypeScript)

Cross-platform cookie extraction for Node.js and Bun. **Requirements**: Node.js >= 22 (`node:sqlite`) or Bun (`bun:sqlite`).

### Installation

```bash
npm install @steipete/sweet-cookie
# or: pnpm add / bun add
```

### Basic Usage

```typescript
import { getCookies, toCookieHeader } from '@steipete/sweet-cookie';

const { cookies, warnings } = await getCookies({
  url: 'https://example.com/',
  names: ['session', 'csrf'],
  browsers: ['chrome', 'edge', 'firefox', 'safari'],
});

for (const warning of warnings) console.warn(warning);

const cookieHeader = toCookieHeader(cookies, { dedupeByName: true });
const response = await fetch('https://api.example.com/data', {
  headers: { Cookie: cookieHeader }
});
```

### Multiple Origins (OAuth/SSO)

```typescript
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
await getCookies({ url: 'https://example.com/', browsers: ['chrome'], chromeProfile: 'Default' });
await getCookies({ url: 'https://example.com/', browsers: ['edge'], edgeProfile: 'Profile 1' });
```

### Inline Cookies (CI/CD)

For environments where browser DB access isn't possible:

```typescript
await getCookies({ url: 'https://example.com/', browsers: ['chrome'], inlineCookiesFile: '/path/to/cookies.json' });
await getCookies({ url: 'https://example.com/', inlineCookiesJson: '{"cookies": [...]}' });
await getCookies({ url: 'https://example.com/', inlineCookiesBase64: 'eyJjb29raWVzIjogWy4uLl19' });
```

### Environment Variables

```bash
SWEET_COOKIE_BROWSERS=chrome,safari,firefox
SWEET_COOKIE_MODE=merge                        # or 'first'
SWEET_COOKIE_CHROME_PROFILE=Default
SWEET_COOKIE_EDGE_PROFILE=Default
SWEET_COOKIE_FIREFOX_PROFILE=default-release
SWEET_COOKIE_LINUX_KEYRING=gnome               # or kwallet, basic
SWEET_COOKIE_CHROME_SAFE_STORAGE_PASSWORD=...
```

### Supported Browsers

| Browser | macOS | Windows | Linux |
|---------|-------|---------|-------|
| Chrome  | Yes   | Yes     | Yes   |
| Edge    | Yes   | Yes     | Yes   |
| Firefox | Yes   | Yes     | Yes   |
| Safari  | Yes   | -       | -     |

### Chrome Extension (App-Bound Cookies)

For Chrome 127+ with app-bound encryption:

1. Install from `apps/extension` in the sweet-cookie repo
2. Export cookies as JSON/base64/file
3. Use `inlineCookiesFile` or `inlineCookiesJson` option

## SweetCookieKit (Swift)

Native macOS cookie extraction. **Requirements**: macOS 13+, Swift 6.

### Installation

```swift
// Package.swift
.package(url: "https://github.com/steipete/SweetCookieKit.git", from: "0.2.0")
```

### Basic Usage

```swift
import SweetCookieKit

let client = BrowserCookieClient()
let stores = client.stores(for: .chrome)
let store = stores.first { $0.profile.name == "Default" }
let query = BrowserCookieQuery(domains: ["example.com"], domainMatch: .suffix, includeExpired: false)
let cookies = try client.cookies(matching: query, in: store!)
```

### Browser Import Order

```swift
let order = Browser.defaultImportOrder
for browser in order {
    let results = try client.records(matching: query, in: browser)
}
```

### Chromium Local Storage & LevelDB

```swift
let entries = ChromiumLocalStorageReader.readEntries(for: "https://example.com", in: levelDBURL)
let tokens = ChromiumLevelDBReader.readTokenCandidates(in: levelDBURL, minimumLength: 80)
```

### CLI Tool

```bash
swift run SweetCookieCLI stores
swift run SweetCookieCLI export --domain example.com --format json
```

## Security Notes

- **Keychain prompts**: Chrome/Edge may trigger Keychain access prompts on macOS
- **Full Disk Access**: Safari requires Full Disk Access permission
- **Browser must be closed**: Some browsers lock their cookie DB while running
- **Encrypted cookies**: Chromium cookies are encrypted; sweet-cookie handles decryption via OS keychain

### Keychain Prompt Handler (Swift)

```swift
BrowserCookieKeychainPromptHandler.shared.handler = { context in
    // context.kind = .chromiumSafeStorage — show blocking alert or custom UI
}
```

## Integration

### With Bird (X/Twitter CLI)

Bird auto-extracts X/Twitter cookies via sweet-cookie:

```bash
bird whoami
bird tweet "Hello from CLI"
```

### With Crawl4AI

```bash
crawl4ai https://app.example.com --cookies /path/to/cookies.json
```

## Resources

- **sweet-cookie (TypeScript)**: https://github.com/steipete/sweet-cookie
- **SweetCookieKit (Swift)**: https://github.com/steipete/SweetCookieKit
- **Documentation**: https://sweetcookie.dev

## Related Tools

- `tools/browser/agent-browser.md` - CLI browser automation (default)
- `tools/browser/stagehand.md` - AI-powered browser automation
- `tools/browser/playwriter.md` - Chrome extension MCP for existing sessions
- `tools/social-media/bird.md` - X/Twitter CLI (uses sweet-cookie)
