---
description: WXT - next-gen framework for cross-browser extension development
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

# WXT - Browser Extension Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Cross-browser extension framework with HMR, auto-imports, TypeScript
- **Docs**: Use Context7 MCP for latest WXT documentation
- **GitHub**: https://github.com/wxt-dev/wxt (5k+ stars, MIT) | **Website**: https://wxt.dev
- **Used by**: TurboStarter (`~/Git/turbostarter/core/apps/extension/`)

| Feature | WXT | Plasmo | Vanilla MV3 |
|---------|-----|--------|-------------|
| Cross-browser | Chrome, Firefox, Edge, Safari | Chrome, Firefox, Edge | Manual |
| HMR | Full (popup, content, background) | Partial | None |
| Auto-imports | Yes (Vite-based) | No | No |
| UI framework | React, Vue, Svelte, Solid | React | Any |
| TypeScript | First-class | First-class | Manual |
| MV2 + MV3 | Both (auto-converts) | MV3 only | Manual |
| File-based entrypoints | Yes | Yes | No |
| Bundle analysis | Built-in | No | Manual |

<!-- AI-CONTEXT-END -->

## Quick Start

```bash
npx wxt@latest init my-extension    # Choose: React, Vue, Svelte, Solid, Vanilla
cd my-extension && npm install

npm run dev              # Dev with HMR (Chrome)
npm run dev:firefox      # Dev (Firefox)
npm run build            # Production → .output/chrome-mv3/
npm run build:firefox    # Production → .output/firefox-mv2/
npm run zip              # Package → .output/chrome-mv3.zip
npm run zip:firefox      # Package → .output/firefox-mv2.zip
```

Direct CLI: `wxt build -b edge` → `.output/edge-mv3/` | `wxt build -b safari` → `.output/safari-mv3/`

## Project Structure

```text
my-extension/
├── wxt.config.ts              # WXT configuration
├── entrypoints/               # Auto-discovered entry points
│   ├── background.ts          # Service worker
│   ├── content.ts             # Content script (or content/index.ts)
│   ├── popup/                 # Popup UI (index.html + main.tsx)
│   ├── options/               # Options page
│   ├── sidepanel/             # Side panel (Chrome 114+)
│   └── newtab/                # New tab override
├── components/                # Shared components
├── hooks/                     # Shared hooks
├── utils/                     # Shared utilities
├── assets/                    # Static assets (icon.png)
└── public/                    # Copied to output as-is
```

## Configuration

```typescript
// wxt.config.ts
import { defineConfig } from 'wxt';

export default defineConfig({
  modules: ['@wxt-dev/module-react'],  // or vue, svelte, solid
  manifest: {
    name: 'My Extension',
    description: 'A great extension',
    permissions: ['storage', 'activeTab'],
    host_permissions: ['https://api.example.com/*'],
  },
  runner: {
    startUrls: ['https://example.com'],  // Open on dev start
  },
});
```

## Entrypoints

Auto-discovered from `entrypoints/`. Each exports config via `defineBackground`, `defineContentScript`, etc.

### Background (Service Worker)

```typescript
// entrypoints/background.ts
export default defineBackground(() => {
  browser.runtime.onMessage.addListener((message, sender) => {
    if (message.type === 'getData') return fetchData(message.url);
  });
  browser.alarms.create('sync', { periodInMinutes: 30 });
  browser.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === 'sync') syncData();
  });
});
```

### Content Script

```typescript
// entrypoints/content.ts — basic injection
export default defineContentScript({
  matches: ['https://*.example.com/*'],
  runAt: 'document_idle',
  main() {
    console.log('Content script loaded on', window.location.href);
  },
});
```

### Content Script with UI (Shadow DOM)

```typescript
// entrypoints/content/index.tsx — with React UI in shadow DOM
import ReactDOM from 'react-dom/client';
import App from './App';

export default defineContentScript({
  matches: ['https://*.example.com/*'],
  cssInjectionMode: 'ui',
  async main(ctx) {
    const ui = await createShadowRootUi(ctx, {
      name: 'my-extension-ui',
      position: 'inline',
      anchor: 'body',
      onMount: (container) => {
        const root = ReactDOM.createRoot(container);
        root.render(<App />);
        return root;
      },
      onRemove: (root) => root?.unmount(),
    });
    ui.mount();
  },
});
```

## Storage

Typed storage API with sync/local/session areas:

```typescript
// utils/storage.ts
import { storage } from 'wxt/storage';

export const userPreferences = storage.defineItem<{
  theme: 'light' | 'dark';
  notifications: boolean;
}>('sync:preferences', {
  fallback: { theme: 'light', notifications: true },
});

// Usage: getValue, setValue, watch
const prefs = await userPreferences.getValue();
await userPreferences.setValue({ theme: 'dark', notifications: true });
userPreferences.watch((newValue) => console.log('Changed:', newValue));
```

## Messaging

Type-safe messaging between extension contexts via `@webext-core/messaging`:

```typescript
// utils/messaging.ts
import { defineExtensionMessaging } from '@webext-core/messaging';

interface ProtocolMap {
  getData: (url: string) => { data: string };
  getTab: () => { tabId: number };
}
export const { sendMessage, onMessage } = defineExtensionMessaging<ProtocolMap>();

// Background: onMessage('getData', async ({ data: url }) => { ... });
// Caller:     const result = await sendMessage('getData', 'https://api.example.com/data');
```

## Cross-Browser

`browser` namespace auto-polyfilled for Chrome; correct manifest format per browser; MV2/MV3 differences handled automatically. Conditional: `import.meta.env.BROWSER === 'firefox'`.

## Related

- `tools/browser/extension-dev.md` - Full extension development lifecycle
- `tools/browser/extension-dev/development.md` - Architecture and patterns
- `tools/browser/extension-dev/testing.md` - Testing extensions
- `tools/browser/extension-dev/publishing.md` - Store submission
- `tools/browser/chrome-webstore-release.md` - Chrome Web Store CI/CD
- `tools/ui/tailwind-css.md` - Styling with Tailwind
- `tools/ui/shadcn.md` - UI components
