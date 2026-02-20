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

# WXT - Browser Extension Framework

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Modern framework for building cross-browser extensions with HMR, auto-imports, and TypeScript
- **Docs**: Use Context7 MCP for latest WXT documentation
- **GitHub**: https://github.com/wxt-dev/wxt (5k+ stars, MIT)
- **Website**: https://wxt.dev
- **Used by**: TurboStarter (`~/Git/turbostarter/core/apps/extension/`)

**Why WXT over alternatives**:

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
# Create new project
npx wxt@latest init my-extension
# Choose: React, Vue, Svelte, Solid, or Vanilla

cd my-extension
npm install

# Development (Chrome with HMR)
npm run dev

# Development (Firefox)
npm run dev:firefox

# Production build
npm run build           # Chrome MV3
npm run build:firefox   # Firefox MV2/MV3

# Package for store submission
npm run zip             # Creates .zip for Chrome Web Store
npm run zip:firefox     # Creates .zip for Firefox Add-ons
```

## Project Structure

```text
my-extension/
├── wxt.config.ts              # WXT configuration
├── package.json
├── tsconfig.json
├── entrypoints/               # Auto-discovered entry points
│   ├── background.ts          # Service worker
│   ├── content.ts             # Content script (or content/index.ts)
│   ├── popup/                 # Popup UI
│   │   ├── index.html
│   │   └── main.tsx
│   ├── options/               # Options page
│   │   ├── index.html
│   │   └── main.tsx
│   ├── sidepanel/             # Side panel (Chrome 114+)
│   │   ├── index.html
│   │   └── main.tsx
│   └── newtab/                # New tab override
│       ├── index.html
│       └── main.tsx
├── components/                # Shared components
├── hooks/                     # Shared hooks
├── utils/                     # Shared utilities
├── assets/                    # Static assets
│   └── icon.png               # Extension icon
└── public/                    # Copied to output as-is
```

## Configuration

```typescript
// wxt.config.ts
import { defineConfig } from 'wxt';

export default defineConfig({
  // UI framework
  modules: ['@wxt-dev/module-react'],  // or vue, svelte, solid

  // Manifest configuration
  manifest: {
    name: 'My Extension',
    description: 'A great extension',
    permissions: ['storage', 'activeTab'],
    host_permissions: ['https://api.example.com/*'],
  },

  // Build targets
  // WXT auto-generates correct manifest for each browser
  runner: {
    startUrls: ['https://example.com'],  // Open on dev start
  },
});
```

## Entrypoint Configuration

Each entrypoint file exports configuration via `defineBackground`, `defineContentScript`, etc.:

### Background (Service Worker)

```typescript
// entrypoints/background.ts
export default defineBackground(() => {
  console.log('Extension started');

  // Listen for messages
  browser.runtime.onMessage.addListener((message, sender) => {
    if (message.type === 'getData') {
      return fetchData(message.url);
    }
  });

  // Alarms for periodic tasks
  browser.alarms.create('sync', { periodInMinutes: 30 });
  browser.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === 'sync') syncData();
  });
});
```

### Content Script

```typescript
// entrypoints/content.ts
export default defineContentScript({
  matches: ['https://*.example.com/*'],
  runAt: 'document_idle',

  main() {
    console.log('Content script loaded on', window.location.href);
    // Modify page, inject UI, etc.
  },
});
```

### Content Script with UI (Shadow DOM)

```typescript
// entrypoints/content/index.tsx
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
      onRemove: (root) => {
        root?.unmount();
      },
    });
    ui.mount();
  },
});
```

## Storage

WXT provides a typed storage API:

```typescript
// utils/storage.ts
import { storage } from 'wxt/storage';

// Define typed storage items
export const userPreferences = storage.defineItem<{
  theme: 'light' | 'dark';
  notifications: boolean;
}>('sync:preferences', {
  fallback: { theme: 'light', notifications: true },
});

// Usage
const prefs = await userPreferences.getValue();
await userPreferences.setValue({ theme: 'dark', notifications: true });

// Watch for changes
userPreferences.watch((newValue) => {
  console.log('Preferences changed:', newValue);
});
```

## Messaging

Type-safe messaging between extension contexts:

```typescript
// utils/messaging.ts
import { defineExtensionMessaging } from '@webext-core/messaging';

interface ProtocolMap {
  getData: (url: string) => { data: string };
  getTab: () => { tabId: number };
}

export const { sendMessage, onMessage } = defineExtensionMessaging<ProtocolMap>();

// Background handler
onMessage('getData', async ({ data: url }) => {
  const response = await fetch(url);
  return { data: await response.text() };
});

// Content script / popup caller
const result = await sendMessage('getData', 'https://api.example.com/data');
```

## Cross-Browser

WXT automatically handles browser differences:

- Uses `browser` namespace (auto-polyfilled for Chrome)
- Generates correct manifest format per browser
- Handles MV2 vs MV3 differences
- Conditional code via `import.meta.env.BROWSER`:

```typescript
if (import.meta.env.BROWSER === 'firefox') {
  // Firefox-specific code
}
```

## Build Commands

| Command | Output |
|---------|--------|
| `wxt build` | `.output/chrome-mv3/` |
| `wxt build -b firefox` | `.output/firefox-mv2/` |
| `wxt build -b edge` | `.output/edge-mv3/` |
| `wxt build -b safari` | `.output/safari-mv3/` |
| `wxt zip` | `.output/chrome-mv3.zip` |
| `wxt zip -b firefox` | `.output/firefox-mv2.zip` |

## Related

- `browser-extension-dev.md` - Full extension development lifecycle
- `browser-extension-dev/development.md` - Architecture and patterns
- `browser-extension-dev/testing.md` - Testing extensions
- `browser-extension-dev/publishing.md` - Store submission
- `tools/browser/chrome-webstore-release.md` - Chrome Web Store CI/CD
- `tools/ui/tailwind-css.md` - Styling with Tailwind
- `tools/ui/shadcn.md` - UI components
