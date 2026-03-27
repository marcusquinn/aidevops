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

- **Framework**: WXT (recommended), Plasmo, or vanilla Manifest V3
- **Docs**: Use Context7 MCP for latest WXT, Plasmo, and WebExtension API docs
- **Reference**: TurboStarter extension structure at `~/Git/turbostarter/core/apps/extension/`

```bash
npx wxt@latest init my-extension && cd my-extension
npm run dev        # Dev mode with HMR
npm run build      # Production build
```

<!-- AI-CONTEXT-END -->

## Project Structure (WXT)

```text
my-extension/
├── wxt.config.ts                    # WXT configuration
├── src/
│   ├── entrypoints/                 # background.ts, content.ts, popup/, options/, sidepanel/, newtab/
│   ├── components/ hooks/           # Shared UI + React hooks
│   ├── lib/                         # storage.ts, messaging.ts, api.ts
│   └── assets/                      # Icons (128x128 min), images
└── .output/                         # chrome-mv3/, firefox-mv2/
```

## Entry Points

| Entry Point | Purpose | Manifest Key |
|-------------|---------|-------------|
| **Background** (Service Worker) | Event handling, API calls, state | `background.service_worker` |
| **Content Script** | Modify web pages, inject UI | `content_scripts` |
| **Popup** | Quick actions (click icon) | `action.default_popup` |
| **Options** | Settings page | `options_ui` |
| **Side Panel** | Persistent sidebar (Chrome 114+) | `side_panel` |
| **New Tab** | Override new tab | `chrome_url_overrides.newtab` |
| **DevTools** | Developer tools panel | `devtools_page` |

## Message Passing

```typescript
// Content script -> Background
chrome.runtime.sendMessage({ type: 'getData', url: window.location.href });

// Background -> Content script
chrome.tabs.sendMessage(tabId, { type: 'updateUI', data: result });

// Background handler — return true to keep channel open for async
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'getData') {
    fetchData(message.url).then(sendResponse);
    return true;
  }
});
```

## Storage

```typescript
await chrome.storage.sync.set({ preferences: { theme: 'dark' } });   // Syncs across devices, 100KB limit
await chrome.storage.local.set({ cache: largeData });                 // Device-only, 5MB limit
await chrome.storage.session.set({ tempToken: 'abc' });               // Cleared on restart, MV3 only
const { preferences } = await chrome.storage.sync.get('preferences');
```

## Permissions

Request only what you need. Prefer optional permissions (requested at runtime):

```json
{
  "permissions": ["storage", "activeTab"],
  "optional_permissions": ["tabs", "bookmarks", "history"],
  "host_permissions": ["https://api.example.com/*"]
}
```

```typescript
const granted = await chrome.permissions.request({ permissions: ['tabs'], origins: ['https://*.example.com/*'] });
```

## Cross-Browser Compatibility

| Feature | Chrome (MV3) | Firefox (MV2/MV3) |
|---------|-------------|-------------------|
| Background | `service_worker` | `scripts` (MV2) / `service_worker` (MV3) |
| Action | `action` | `browser_action` (MV2) / `action` (MV3) |
| Host permissions | `host_permissions` | `permissions` (MV2) / `host_permissions` (MV3) |
| Side panel | Chrome 114+ | Not supported |
| CSP | `content_security_policy.extension_pages` | `content_security_policy` (string) |

WXT handles most differences automatically. For manual compat: `import browser from 'webextension-polyfill'`.

## Development Standards

- **TypeScript** always — type messages, storage schemas, API responses
- **UI**: React (recommended), Vue (WXT first-class), Svelte (smallest bundle), or vanilla
- **Styling**: Tailwind CSS (recommended), CSS Modules, or Shadow DOM for content scripts

Content script UI isolation — Shadow DOM prevents host page style conflicts:

```typescript
const host = document.createElement('div');
const shadow = host.attachShadow({ mode: 'closed' });
shadow.innerHTML = `
  <style>/* Isolated styles */</style>
  <div id="app"><!-- Your UI --></div>
`;
document.body.appendChild(host);
```

## Performance & Security

- Service worker is unloaded when idle (MV3) — keep lightweight
- `chrome.alarms` over `setInterval`; `chrome.storage` listeners over polling
- Lazy-load heavy deps; minimise content script `matches` scope
- Never store secrets in extension code — use backend API
- Validate all inter-context messages; sanitise injected HTML
- Enforce CSP; prefer `activeTab` over broad host permissions

## Related

- **Extension dev**: `testing.md`, `publishing.md`, `chrome-webstore-release.md` (in `tools/browser/`)
- **UI/Styling**: `tools/ui/wxt.md`, `tools/ui/tailwind-css.md`, `tools/ui/shadcn.md`
- **Backend**: `tools/api/hono.md`, `tools/api/better-auth.md`, `services/payments/stripe.md`
- **Design**: `product/ui-design.md`
