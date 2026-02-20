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
- **Levels**: Unit -> Integration -> E2E -> Cross-browser -> Performance

**Testing tool decision tree**:

```text
Need E2E testing with extension loaded?
  -> Playwright (supports loading extensions in Chromium)

Need to debug service worker?
  -> chrome://extensions -> Inspect service worker

Need to debug content scripts?
  -> Browser DevTools -> Sources -> Content scripts

Need cross-browser verification?
  -> Test in Chrome + Firefox + Edge manually or via CI
```

<!-- AI-CONTEXT-END -->

## Testing Strategy

### Unit Tests

Test business logic in isolation:

```bash
# Using Vitest (recommended with WXT)
npm run test

# Or Jest
npx jest
```

Cover:

- Message parsing and handling
- Storage read/write logic
- Data transformations
- API client functions

### E2E Testing with Playwright

Playwright can load unpacked extensions in Chromium:

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

  // Get extension ID from service worker
  let extensionId: string;
  const serviceWorkers = context.serviceWorkers();
  if (serviceWorkers.length > 0) {
    extensionId = serviceWorkers[0].url().split('/')[2];
  } else {
    const sw = await context.waitForEvent('serviceworker');
    extensionId = sw.url().split('/')[2];
  }

  // Open popup
  const popup = await context.newPage();
  await popup.goto(`chrome-extension://${extensionId}/popup.html`);

  // Test popup UI
  await popup.click('button#action');
  await popup.waitForSelector('#result');

  await context.close();
});
```

### Manual Testing Checklist

**Chrome/Chromium**:

- [ ] Load unpacked extension from `.output/chrome-mv3/`
- [ ] Popup opens and functions correctly
- [ ] Content scripts inject on target pages
- [ ] Service worker handles events
- [ ] Storage persists across sessions
- [ ] Options page saves preferences
- [ ] Side panel works (if applicable)
- [ ] Permissions requested correctly

**Firefox**:

- [ ] Load temporary add-on from `.output/firefox-mv2/` (or MV3)
- [ ] All features work as in Chrome
- [ ] Firefox-specific APIs handled
- [ ] No console errors

**Edge**:

- [ ] Load unpacked from `.output/chrome-mv3/` (same build)
- [ ] Edge-specific features work (if any)

### Debugging

**Service Worker**:

1. Navigate to `chrome://extensions`
2. Find your extension
3. Click "Inspect views: service worker"
4. Use DevTools Console and Sources

**Content Scripts**:

1. Open target web page
2. Open DevTools (F12)
3. Go to Sources -> Content scripts
4. Set breakpoints and debug

**Popup**:

1. Right-click extension icon
2. Select "Inspect popup"
3. DevTools opens for popup context

**Storage**:

```javascript
// In DevTools console (any extension context)
chrome.storage.local.get(null, console.log);
chrome.storage.sync.get(null, console.log);
```

## Cross-Browser CI

### GitHub Actions

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

Before submitting to stores:

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

- `browser-extension-dev/development.md` - Development setup
- `browser-extension-dev/publishing.md` - Store submission
- `tools/browser/playwright.md` - Playwright testing
- `tools/browser/chrome-devtools.md` - Chrome DevTools
