---
description: Browser extension development - WXT/Plasmo/MV3 setup, architecture, APIs, cross-browser patterns
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

# Extension Development - Cross-Browser Extensions

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Build cross-browser extensions with modern tooling
- **Framework**: WXT (recommended), Plasmo, or vanilla Manifest V3
- **Docs**: Use Context7 MCP for latest WXT, Plasmo, and WebExtension API docs
- **Reference**: TurboStarter extension structure at `~/Git/turbostarter/core/apps/extension/`

**WXT scaffold**:

```bash
npx wxt@latest init my-extension
cd my-extension
npm run dev        # Dev mode with HMR
npm run build      # Production build
```

<!-- AI-CONTEXT-END -->

## Project Structure (WXT)

```text
my-extension/
├── wxt.config.ts            # WXT configuration
├── package.json
├── tsconfig.json
├── src/
│   ├── entrypoints/         # Extension entry points
│   │   ├── background.ts    # Service worker
│   │   ├── content.ts       # Content script
│   │   ├── popup/           # Popup UI
│   │   │   ├── index.html
│   │   │   ├── App.tsx
│   │   │   └── style.css
│   │   ├── options/         # Options page
│   │   │   ├── index.html
│   │   │   └── App.tsx
│   │   ├── sidepanel/       # Side panel (Chrome 114+)
│   │   │   ├── index.html
│   │   │   └── App.tsx
│   │   └── newtab/          # New tab override
│   │       ├── index.html
│   │       └── App.tsx
│   ├── components/          # Shared UI components
│   ├── hooks/               # Shared React hooks
│   ├── lib/                 # Utilities
│   │   ├── storage.ts       # Storage abstraction
│   │   ├── messaging.ts     # Message passing
│   │   └── api.ts           # Backend API client
│   ├── assets/              # Icons, images
│   │   └── icon.png         # Extension icon (128x128 minimum)
│   └── styles/              # Global styles
│       └── globals.css
├── public/                  # Static assets
└── .output/                 # Build output
    ├── chrome-mv3/          # Chrome build
    └── firefox-mv2/         # Firefox build
```

## Extension Architecture

### Entry Points

| Entry Point | Purpose | Manifest Key |
|-------------|---------|-------------|
| **Background** (Service Worker) | Event handling, API calls, state management | `background.service_worker` |
| **Content Script** | Modify web pages, inject UI, read page data | `content_scripts` |
| **Popup** | Quick actions UI (click extension icon) | `action.default_popup` |
| **Options** | Settings and configuration page | `options_ui` |
| **Side Panel** | Persistent sidebar UI (Chrome 114+) | `side_panel` |
| **New Tab** | Override new tab page | `chrome_url_overrides.newtab` |
| **DevTools** | Developer tools panel | `devtools_page` |

### Communication Patterns

```text
Content Script <-> Background (Service Worker) <-> Popup/Options/SidePanel
       |                    |
       v                    v
   Web Page            External APIs
```

**Message passing**:

```typescript
// Content script -> Background
chrome.runtime.sendMessage({ type: 'getData', url: window.location.href });

// Background -> Content script
chrome.tabs.sendMessage(tabId, { type: 'updateUI', data: result });

// Background message handler
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'getData') {
    fetchData(message.url).then(sendResponse);
    return true; // Keep channel open for async response
  }
});
```

### Storage

```typescript
// Sync storage (syncs across devices, 100KB limit)
await chrome.storage.sync.set({ preferences: { theme: 'dark' } });
const { preferences } = await chrome.storage.sync.get('preferences');

// Local storage (device-only, 5MB limit)
await chrome.storage.local.set({ cache: largeData });

// Session storage (cleared on browser restart, MV3 only)
await chrome.storage.session.set({ tempToken: 'abc' });
```

### Permissions

Request only what you need. Prefer optional permissions:

```json
{
  "permissions": ["storage", "activeTab"],
  "optional_permissions": ["tabs", "bookmarks", "history"],
  "host_permissions": ["https://api.example.com/*"]
}
```

**Optional permissions** (requested at runtime):

```typescript
const granted = await chrome.permissions.request({
  permissions: ['tabs'],
  origins: ['https://*.example.com/*'],
});
```

## Cross-Browser Compatibility

### Manifest Differences

| Feature | Chrome (MV3) | Firefox (MV2/MV3) |
|---------|-------------|-------------------|
| Background | `service_worker` | `scripts` (MV2) or `service_worker` (MV3) |
| Action | `action` | `browser_action` (MV2) or `action` (MV3) |
| Host permissions | `host_permissions` | `permissions` (MV2) or `host_permissions` (MV3) |
| Side panel | Supported (Chrome 114+) | Not supported |
| Content security | `content_security_policy.extension_pages` | `content_security_policy` (string) |

WXT handles most of these differences automatically.

### Browser-Specific APIs

```typescript
// Use webextension-polyfill for cross-browser compatibility
import browser from 'webextension-polyfill';

// Or check for API availability
if (chrome.sidePanel) {
  // Chrome-specific side panel
}
```

## Development Standards

### TypeScript

Always use TypeScript. Define types for all messages, storage schemas, and API responses.

### UI Framework

- **React** (recommended): Largest ecosystem, TurboStarter uses it
- **Vue**: Good alternative, WXT has first-class support
- **Svelte**: Smallest bundle size, WXT supports it
- **Vanilla**: For minimal extensions

### Styling

- **Tailwind CSS**: Recommended for rapid development
- **CSS Modules**: For component isolation
- **Shadow DOM**: For content script UI (prevents host page style conflicts)

### Content Script UI Isolation

When injecting UI into web pages, use Shadow DOM to prevent style conflicts:

```typescript
const host = document.createElement('div');
const shadow = host.attachShadow({ mode: 'closed' });
shadow.innerHTML = `
  <style>/* Your isolated styles */</style>
  <div id="app"><!-- Your UI --></div>
`;
document.body.appendChild(host);
```

## Performance

- Keep service worker lightweight (it's unloaded when idle in MV3)
- Use `chrome.alarms` instead of `setInterval` for periodic tasks
- Lazy-load heavy dependencies
- Minimise content script injection (use `matches` patterns carefully)
- Use `chrome.storage` change listeners instead of polling

## Security

- Never store secrets in extension code (use backend API)
- Validate all messages between contexts
- Use Content Security Policy (CSP)
- Sanitise any HTML injected into pages
- Request minimal permissions
- Use `activeTab` instead of broad host permissions when possible

## Related

- `browser-extension-dev/testing.md` - Testing extensions
- `browser-extension-dev/publishing.md` - Store submission
- `tools/browser/chrome-webstore-release.md` - Chrome Web Store automation
- `tools/ui/wxt.md` - Dedicated WXT framework agent
- `tools/ui/tailwind-css.md` - Tailwind CSS styling
- `tools/ui/shadcn.md` - shadcn/ui components (for extension UIs)
- `tools/ui/react-email.md` - React Email (for transactional emails)
- `tools/api/hono.md` - Hono API framework (for extension backends)
- `tools/api/better-auth.md` - Authentication
- `services/payments/stripe.md` - Stripe payments (for premium extensions)
- `mobile-app-dev/ui-design.md` - Design standards (shared)
