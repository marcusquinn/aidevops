---
description: Playwright device emulation for mobile, tablet, and responsive testing
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

# Playwright Device Emulation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Mobile, tablet, and responsive testing via Playwright device emulation
- **Docs**: https://playwright.dev/docs/emulation
- **Device registry**: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/deviceDescriptorsSource.json
- **Requires**: `npm install playwright` (or `@playwright/test` for test runner)

**Capabilities**:

- Device presets (iPhone, iPad, Pixel, Galaxy, desktop)
- Custom viewport and screen size
- User agent override
- Touch event emulation (`hasTouch`, `isMobile`)
- Geolocation spoofing
- Locale and timezone emulation
- Permission grants (notifications, geolocation, camera, microphone)
- Color scheme (`light`, `dark`)
- Reduced motion (`reduce`, `no-preference`)
- Forced colors (`active`, `none`)
- Offline mode
- JavaScript disabled mode
- Device scale factor (HiDPI/Retina)

**When to use**: Testing responsive layouts, mobile-specific behavior, touch interactions, geolocation features, locale-dependent content, dark mode, or any scenario requiring browser environment emulation. Complements native mobile testing (Maestro, iOS Simulator MCP) for web-based mobile testing.

<!-- AI-CONTEXT-END -->

## Device Presets

Playwright ships with a registry of 100+ device descriptors. Each preset includes `viewport`, `userAgent`, `deviceScaleFactor`, `isMobile`, and `hasTouch`.

### Common Devices

| Device | Viewport | Scale | Mobile | Touch |
|--------|----------|-------|--------|-------|
| `Desktop Chrome` | 1280x720 | 1 | No | No |
| `Desktop Firefox` | 1280x720 | 1 | No | No |
| `Desktop Safari` | 1280x720 | 1 | No | No |
| `Desktop Edge` | 1280x720 | 1 | No | No |
| `iPhone 12` | 390x844 | 3 | Yes | Yes |
| `iPhone 13` | 390x844 | 3 | Yes | Yes |
| `iPhone 13 Pro Max` | 428x926 | 3 | Yes | Yes |
| `iPhone 14` | 390x844 | 3 | Yes | Yes |
| `iPhone 14 Pro Max` | 430x932 | 3 | Yes | Yes |
| `iPhone 15` | 393x852 | 3 | Yes | Yes |
| `iPhone 15 Pro Max` | 430x932 | 3 | Yes | Yes |
| `iPad (gen 7)` | 810x1080 | 2 | Yes | Yes |
| `iPad Mini` | 768x1024 | 2 | Yes | Yes |
| `iPad Pro 11` | 834x1194 | 2 | Yes | Yes |
| `Pixel 5` | 393x851 | 2.75 | Yes | Yes |
| `Pixel 7` | 412x915 | 2.625 | Yes | Yes |
| `Galaxy S8` | 360x740 | 3 | Yes | Yes |
| `Galaxy S9+` | 320x658 | 4.5 | Yes | Yes |
| `Galaxy Tab S4` | 712x1138 | 2.25 | Yes | Yes |

### List All Available Devices

```javascript
const { devices } = require('playwright');
console.log(Object.keys(devices));
```

```bash
node -e "const { devices } = require('playwright'); console.log(Object.keys(devices).join('\n'))"
```

### Landscape Variants

Most mobile devices have landscape variants appended with `landscape`:

```javascript
const { devices } = require('playwright');
const iPhoneLandscape = devices['iPhone 13 landscape'];
```

## Configuration

### Test Runner (playwright.config.ts)

Configure device emulation per project:

```typescript
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  projects: [
    {
      name: 'Desktop Chrome',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'Mobile Safari',
      use: { ...devices['iPhone 13'] },
    },
    {
      name: 'Mobile Chrome',
      use: { ...devices['Pixel 7'] },
    },
    {
      name: 'Tablet',
      use: { ...devices['iPad Pro 11'] },
    },
  ],
});
```

### Library API (Direct Usage)

```javascript
const { chromium, devices } = require('playwright');

const browser = await chromium.launch();
const iPhone = devices['iPhone 13'];
const context = await browser.newContext({
  ...iPhone,
});
const page = await context.newPage();
await page.goto('https://example.com');
```

## Viewport Emulation

### Global Config

```typescript
// playwright.config.ts
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1280, height: 720 },
      },
    },
  ],
});
```

### Per-Test Override

```typescript
import { test, expect } from '@playwright/test';

test.use({
  viewport: { width: 1600, height: 1200 },
});

test('wide viewport test', async ({ page }) => {
  await page.goto('https://example.com');
  // Test wide layout
});
```

### Dynamic Resize

```javascript
await page.setViewportSize({ width: 375, height: 667 });
// Test mobile layout
await page.setViewportSize({ width: 1920, height: 1080 });
// Test desktop layout
```

### HiDPI / Retina

```javascript
const context = await browser.newContext({
  viewport: { width: 2560, height: 1440 },
  deviceScaleFactor: 2,
});
```

## Geolocation

### Config-Level

```typescript
// playwright.config.ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  use: {
    geolocation: { longitude: -122.4194, latitude: 37.7749 },
    permissions: ['geolocation'],
  },
});
```

### Per-Test

```typescript
test.use({
  geolocation: { longitude: 12.4924, latitude: 41.8899 },
  permissions: ['geolocation'],
});

test('Rome geolocation', async ({ page }) => {
  await page.goto('https://maps.google.com');
});
```

### Dynamic Change

```javascript
await context.setGeolocation({ longitude: 48.8584, latitude: 2.2945 });
```

## Locale and Timezone

### Config-Level

```typescript
// playwright.config.ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  use: {
    locale: 'en-GB',
    timezoneId: 'Europe/London',
  },
});
```

### Per-Test

```typescript
test.use({
  locale: 'de-DE',
  timezoneId: 'Europe/Berlin',
});

test('German locale test', async ({ page }) => {
  await page.goto('https://example.com');
  // Date/number formatting will use German locale
});
```

### Common Locale/Timezone Combinations

| Market | Locale | Timezone |
|--------|--------|----------|
| US West | `en-US` | `America/Los_Angeles` |
| US East | `en-US` | `America/New_York` |
| UK | `en-GB` | `Europe/London` |
| Germany | `de-DE` | `Europe/Berlin` |
| France | `fr-FR` | `Europe/Paris` |
| Japan | `ja-JP` | `Asia/Tokyo` |
| China | `zh-CN` | `Asia/Shanghai` |
| India | `hi-IN` | `Asia/Kolkata` |
| Brazil | `pt-BR` | `America/Sao_Paulo` |
| Australia | `en-AU` | `Australia/Sydney` |

## Color Scheme and Media

### Dark Mode

```typescript
// Config
export default defineConfig({
  use: {
    colorScheme: 'dark',
  },
});

// Per-test
test.use({ colorScheme: 'dark' });

// Dynamic
await page.emulateMedia({ colorScheme: 'dark' });
```

### Reduced Motion

```javascript
await page.emulateMedia({ reducedMotion: 'reduce' });
```

### Forced Colors (High Contrast)

```javascript
await page.emulateMedia({ forcedColors: 'active' });
```

### Print Media

```javascript
await page.emulateMedia({ media: 'print' });
```

## Permissions

### Grant Permissions

```typescript
// Config
export default defineConfig({
  use: {
    permissions: ['notifications'],
  },
});

// Per-context (domain-specific)
await context.grantPermissions(['geolocation'], { origin: 'https://example.com' });
await context.grantPermissions(['notifications', 'camera', 'microphone']);
```

### Available Permissions

`geolocation`, `midi`, `midi-sysex`, `notifications`, `camera`, `microphone`, `background-sync`, `ambient-light-sensor`, `accelerometer`, `gyroscope`, `magnetometer`, `accessibility-events`, `clipboard-read`, `clipboard-write`, `payment-handler`

### Revoke Permissions

```javascript
await context.clearPermissions();
```

## Offline Mode

```typescript
// Config
export default defineConfig({
  use: {
    offline: true,
  },
});

// Per-context
const context = await browser.newContext({ offline: true });

// Dynamic toggle
await context.setOffline(true);
// ... test offline behavior
await context.setOffline(false);
```

## JavaScript Disabled

```typescript
test.use({ javaScriptEnabled: false });

test('no-JS fallback', async ({ page }) => {
  await page.goto('https://example.com');
  // Test progressive enhancement / noscript fallback
});
```

## User Agent Override

```typescript
test.use({ userAgent: 'Custom Bot/1.0' });

test('custom user agent', async ({ page }) => {
  await page.goto('https://httpbin.org/user-agent');
});
```

## Recipes

### Responsive Breakpoint Testing

Test all common breakpoints in a single test file:

```typescript
import { test, expect, devices } from '@playwright/test';

const breakpoints = [
  { name: 'mobile-sm', width: 320, height: 568 },
  { name: 'mobile-md', width: 375, height: 667 },
  { name: 'mobile-lg', width: 428, height: 926 },
  { name: 'tablet', width: 768, height: 1024 },
  { name: 'laptop', width: 1024, height: 768 },
  { name: 'desktop', width: 1280, height: 800 },
  { name: 'desktop-lg', width: 1920, height: 1080 },
];

for (const bp of breakpoints) {
  test(`layout at ${bp.name} (${bp.width}x${bp.height})`, async ({ browser }) => {
    const context = await browser.newContext({
      viewport: { width: bp.width, height: bp.height },
    });
    const page = await context.newPage();
    await page.goto('https://example.com');
    await expect(page).toHaveScreenshot(`${bp.name}.png`);
    await context.close();
  });
}
```

### Multi-Device Parallel Testing

```typescript
import { test, devices } from '@playwright/test';

const testDevices = [
  { name: 'iPhone 13', device: devices['iPhone 13'] },
  { name: 'Pixel 7', device: devices['Pixel 7'] },
  { name: 'iPad Pro 11', device: devices['iPad Pro 11'] },
  { name: 'Desktop', device: { viewport: { width: 1280, height: 720 } } },
];

for (const { name, device } of testDevices) {
  test.describe(`${name}`, () => {
    test.use({ ...device });

    test('homepage loads', async ({ page }) => {
      await page.goto('https://example.com');
      await page.waitForLoadState('networkidle');
    });

    test('navigation works', async ({ page }) => {
      await page.goto('https://example.com');
      await page.click('nav a:first-child');
    });
  });
}
```

### Touch Gesture Testing

```javascript
const context = await browser.newContext({
  ...devices['iPhone 13'],
  hasTouch: true,
});
const page = await context.newPage();
await page.goto('https://example.com');

// Tap
await page.tap('.button');

// Swipe (via touchscreen)
await page.touchscreen.tap(200, 300);
```

### Geolocation-Dependent Feature Testing

```typescript
const locations = [
  { name: 'New York', geo: { longitude: -74.006, latitude: 40.7128 }, locale: 'en-US' },
  { name: 'London', geo: { longitude: -0.1276, latitude: 51.5074 }, locale: 'en-GB' },
  { name: 'Tokyo', geo: { longitude: 139.6917, latitude: 35.6895 }, locale: 'ja-JP' },
];

for (const loc of locations) {
  test(`store locator from ${loc.name}`, async ({ browser }) => {
    const context = await browser.newContext({
      geolocation: loc.geo,
      permissions: ['geolocation'],
      locale: loc.locale,
    });
    const page = await context.newPage();
    await page.goto('https://example.com/stores');
    // Verify nearest store results
    await context.close();
  });
}
```

### Network Condition Emulation

Playwright does not have built-in network throttling presets, but you can emulate slow networks via CDP (Chromium only):

```javascript
const context = await browser.newContext();
const page = await context.newPage();

// Access CDP session
const cdpSession = await page.context().newCDPSession(page);

// Emulate Slow 3G
await cdpSession.send('Network.emulateNetworkConditions', {
  offline: false,
  downloadThroughput: (500 * 1024) / 8,   // 500 Kbps
  uploadThroughput: (500 * 1024) / 8,
  latency: 400,                             // 400ms RTT
});

await page.goto('https://example.com');

// Emulate Fast 3G
await cdpSession.send('Network.emulateNetworkConditions', {
  offline: false,
  downloadThroughput: (1.5 * 1024 * 1024) / 8,  // 1.5 Mbps
  uploadThroughput: (750 * 1024) / 8,
  latency: 150,
});
```

### Dark Mode Visual Regression

```typescript
for (const scheme of ['light', 'dark'] as const) {
  test(`visual regression (${scheme})`, async ({ browser }) => {
    const context = await browser.newContext({
      colorScheme: scheme,
      viewport: { width: 1280, height: 720 },
    });
    const page = await context.newPage();
    await page.goto('https://example.com');
    await expect(page).toHaveScreenshot(`homepage-${scheme}.png`);
    await context.close();
  });
}
```

## Integration with aidevops Tools

### With Chrome DevTools MCP

Combine device emulation with performance auditing:

```javascript
const context = await browser.newContext({
  ...devices['iPhone 13'],
});
const page = await context.newPage();

// Navigate in mobile emulation
await page.goto('https://example.com');

// Connect Chrome DevTools MCP for Lighthouse mobile audit
// npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222
```

### With Visual Regression (playwright.md)

Device emulation integrates directly with the visual regression patterns documented in `playwright.md`:

```typescript
// Combine device presets with visual regression suite
await playwright.visualRegressionSuite({
  baseUrl: 'https://example.com',
  pages: ['/', '/about', '/contact'],
  viewports: [
    { width: 375, height: 667 },   // Mobile
    { width: 768, height: 1024 },  // Tablet
    { width: 1920, height: 1080 }, // Desktop
  ],
  threshold: 0.2,
});
```

### With Stagehand (Natural Language + Device)

```javascript
const stagehand = new Stagehand({
  env: 'LOCAL',
  browserOptions: {
    ...devices['iPhone 13'],
  },
});
await stagehand.init();
await stagehand.act('tap the hamburger menu');
```

## Related

- `playwright.md` - Core Playwright automation (cross-browser, forms, security, API testing)
- `playwright-cli.md` - CLI-first Playwright for AI agents
- `browser-automation.md` - Tool selection decision tree
- `browser-benchmark.md` - Performance benchmarks across all browser tools
- `pagespeed.md` - PageSpeed Insights integration
- Maestro (t096) - Native mobile E2E testing
- iOS Simulator MCP (t097) - iOS simulator interaction
