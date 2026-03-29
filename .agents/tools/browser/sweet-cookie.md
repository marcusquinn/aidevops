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
- **Use when**: reusing existing browser sessions, authenticated API calls, bypassing automation detection, CI/CD auth state
- **Don't use when**: fresh browser automation → agent-browser/stagehand; simple scraping without auth → crawl4ai

**Decision**:

```text
Need cookies from existing browser session?
    +-> TypeScript/Node.js project? --> @steipete/sweet-cookie
    +-> Swift/macOS native app?     --> SweetCookieKit
    +-> App-bound cookies (Chrome 127+)? --> Chrome extension
```

<!-- AI-CONTEXT-END -->

## @steipete/sweet-cookie (TypeScript)

Cross-platform cookie extraction for Node.js (>=22, `node:sqlite`) and Bun (`bun:sqlite`).

```bash
npm install @steipete/sweet-cookie   # or: pnpm add / bun add
```

### Usage

```typescript
import { getCookies, toCookieHeader } from '@steipete/sweet-cookie';

// Basic
const { cookies, warnings } = await getCookies({
  url: 'https://example.com/',
  names: ['session', 'csrf'],
  browsers: ['chrome', 'edge', 'firefox', 'safari'],
});
for (const warning of warnings) console.warn(warning);
await fetch('https://api.example.com/data', {
  headers: { Cookie: toCookieHeader(cookies, { dedupeByName: true }) }
});

// Multiple origins (OAuth/SSO)
await getCookies({
  url: 'https://app.example.com/',
  origins: ['https://accounts.example.com/', 'https://login.example.com/'],
  names: ['session', 'xsrf'], browsers: ['chrome'], mode: 'merge',
});

// Specific browser profile
await getCookies({ url: 'https://example.com/', browsers: ['chrome'], chromeProfile: 'Default' });
await getCookies({ url: 'https://example.com/', browsers: ['edge'], edgeProfile: 'Profile 1' });

// Inline cookies (CI/CD — when browser DB access isn't possible)
await getCookies({ url: 'https://example.com/', inlineCookiesFile: '/path/to/cookies.json' });
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

**Chrome Extension (App-Bound Cookies, Chrome 127+):** Install from `apps/extension` in the sweet-cookie repo → export cookies as JSON/base64/file → use `inlineCookiesFile` or `inlineCookiesJson`.

## SweetCookieKit (Swift)

Native macOS cookie extraction. **Requirements**: macOS 13+, Swift 6. Install: `.package(url: "https://github.com/steipete/SweetCookieKit.git", from: "0.2.0")`

```swift
import SweetCookieKit

let client = BrowserCookieClient()
let store = client.stores(for: .chrome).first { $0.profile.name == "Default" }
let query = BrowserCookieQuery(domains: ["example.com"], domainMatch: .suffix, includeExpired: false)
let cookies = try client.cookies(matching: query, in: store!)

// Browser import order
for browser in Browser.defaultImportOrder {
    let results = try client.records(matching: query, in: browser)
}

// Chromium Local Storage & LevelDB
let entries = ChromiumLocalStorageReader.readEntries(for: "https://example.com", in: levelDBURL)
let tokens = ChromiumLevelDBReader.readTokenCandidates(in: levelDBURL, minimumLength: 80)
```

**CLI**: `swift run SweetCookieCLI stores` | `swift run SweetCookieCLI export --domain example.com --format json`

## Security Notes

- **Keychain prompts**: Chrome/Edge may trigger Keychain access prompts on macOS
- **Full Disk Access**: Safari requires Full Disk Access permission
- **Browser must be closed**: Some browsers lock their cookie DB while running
- **Encrypted cookies**: Chromium cookies are encrypted; sweet-cookie handles decryption via OS keychain
- **Keychain handler (Swift)**: `BrowserCookieKeychainPromptHandler.shared.handler = { context in /* context.kind = .chromiumSafeStorage */ }`

## Resources & Related

- **sweet-cookie (TypeScript)**: https://github.com/steipete/sweet-cookie
- **SweetCookieKit (Swift)**: https://github.com/steipete/SweetCookieKit
- **Documentation**: https://sweetcookie.dev
- **Bird (X/Twitter CLI)**: auto-extracts X/Twitter cookies — `bird whoami`, `bird tweet "Hello"` → `tools/social-media/bird.md`
- **Crawl4AI**: `crawl4ai https://app.example.com --cookies /path/to/cookies.json`
- `tools/browser/agent-browser.md` - CLI browser automation (default)
- `tools/browser/stagehand.md` - AI-powered browser automation
- `tools/browser/playwriter.md` - Chrome extension MCP for existing sessions
