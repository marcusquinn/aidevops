---
description: Browser extension testing - cross-browser verification, E2E testing, debugging
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Extension Testing - Cross-Browser QA

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Test browser extensions across Chromium browsers and Firefox
- **Tools**: Playwright (E2E), Chrome DevTools, browser-specific debugging
- **Levels**: Unit → Integration → E2E → Cross-browser → Performance

**Testing tool decision tree**:

```text
E2E with extension loaded?   → Playwright (Chromium only)
Debug service worker?        → chrome://extensions → Inspect service worker
Debug content scripts?       → DevTools → Sources → Content scripts
Cross-browser verification?  → Chrome + Firefox + Edge (manual or CI)
```

<!-- AI-CONTEXT-END -->

## Unit Tests

Test business logic in isolation (message parsing, storage, data transforms, API clients):

```bash
npm run test   # Vitest (recommended with WXT)
npx jest       # Jest alternative
```

## E2E Testing with Playwright

Playwright loads unpacked extensions in Chromium only (not Firefox):

```typescript
import { test, chromium } from '@playwright/test';
import path from 'path';

test('extension popup works', async () => {
  const pathToExtension = path.resolve('.output/chrome-mv3');
  const context = await chromium.launchPersistentContext('', {
    headless: false, // Extensions require headed mode
    args: [
      `--disable-extensions-except=${pathToExtension}`,
      `--load-extension=${pathToExtension}`,
    ],
  });

  let extensionId: string;
  const serviceWorkers = context.serviceWorkers();
  if (serviceWorkers.length > 0) {
    extensionId = serviceWorkers[0].url().split('/')[2];
  } else {
    const sw = await context.waitForEvent('serviceworker');
    extensionId = sw.url().split('/')[2];
  }

  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${extensionId}/popup.html`);
  await popup.click('button#action');
  await popup.waitForSelector('#result');
  await context.close();
});
```

## Manual Testing Checklist

**Chrome/Chromium** (load from `.output/chrome-mv3/`):

- [ ] Popup opens and functions correctly
- [ ] Content scripts inject on target pages
- [ ] Service worker handles events
- [ ] Storage persists across sessions
- [ ] Options page saves preferences
- [ ] Side panel works (if applicable)
- [ ] Permissions requested correctly

**Firefox** (load temporary add-on from `.output/firefox-mv2/` or MV3):

- [ ] All features work as in Chrome
- [ ] Firefox-specific APIs handled
- [ ] No console errors

**Edge** (load from `.output/chrome-mv3/` — same build):

- [ ] Edge-specific features work (if any)

## Debugging

**Service Worker**: `chrome://extensions` → find extension → "Inspect views: service worker"

**Content Scripts**: DevTools (F12) → Sources → Content scripts → set breakpoints

**Popup**: Right-click extension icon → "Inspect popup"

**Storage** (DevTools console in any extension context):

```javascript
chrome.storage.local.get(null, console.log);
chrome.storage.sync.get(null, console.log);
```

## Cross-Browser CI

```yaml
name: Extension Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - run: npm ci
      - run: npm run build
      - run: npx playwright install chromium
      - run: npm run test:e2e
```

## Pre-Submission Checklist

- [ ] All unit tests pass
- [ ] E2E tests pass in Chrome
- [ ] Manual testing complete in Firefox and Edge
- [ ] No console errors or warnings
- [ ] Permissions are minimal and justified
- [ ] Content Security Policy is configured
- [ ] No hardcoded API keys or secrets
- [ ] Extension works in incognito mode (if applicable)
- [ ] Extension handles offline gracefully
- [ ] Memory usage is reasonable (check via Task Manager)

## Related

- `tools/browser/extension-dev/development.md` - Development setup
- `tools/browser/extension-dev/publishing.md` - Store submission
- `tools/browser/playwright.md` - Playwright testing
- `tools/browser/chrome-devtools.md` - Chrome DevTools
