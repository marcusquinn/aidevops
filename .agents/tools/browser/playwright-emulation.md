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

**Capabilities**: Device presets (iPhone, iPad, Pixel, Galaxy, desktop), custom viewport/screen size, user agent override, touch events (`hasTouch`, `isMobile`), geolocation, locale/timezone, permissions (notifications, geolocation, camera, microphone), color scheme, reduced motion, forced colors, offline mode, JavaScript disabled, device scale factor (HiDPI/Retina).

**When to use**: Testing responsive layouts, mobile-specific behavior, touch interactions, geolocation features, locale-dependent content, dark mode, or any scenario requiring browser environment emulation. Complements native mobile testing (Maestro, iOS Simulator MCP) for web-based mobile testing.

<!-- AI-CONTEXT-END -->

## Device Presets

Playwright ships with 100+ device descriptors. Each preset includes `viewport`, `userAgent`, `deviceScaleFactor`, `isMobile`, and `hasTouch`.

### Common Devices

| Device | Viewport | Scale | Mobile |
|--------|----------|-------|--------|
| `Desktop Chrome/Firefox/Safari/Edge` | 1280x720 | 1 | No |
| `iPhone 13/14/15` | 390x844 | 3 | Yes |
| `iPhone 13 Pro Max / 14 Pro Max / 15 Pro Max` | 428-430x926-932 | 3 | Yes |
| `iPad (gen 7)` | 810x1080 | 2 | Yes |
| `iPad Mini` | 768x1024 | 2 | Yes |
| `iPad Pro 11` | 834x1194 | 2 | Yes |
| `Pixel 5` | 393x851 | 2.75 | Yes |
| `Pixel 7` | 412x915 | 2.625 | Yes |
| `Galaxy S8` | 360x740 | 3 | Yes |
| `Galaxy S9+` | 320x658 | 4.5 | Yes |
| `Galaxy Tab S4` | 712x1138 | 2.25 | Yes |

```bash
# List all available devices
node -e "const { devices } = require('playwright'); console.log(Object.keys(devices).join('\n'))"
```

Most mobile devices have landscape variants: `devices['iPhone 13 landscape']`

## Configuration

### Test Runner (playwright.config.ts)

```typescript
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  projects: [
    { name: 'Desktop Chrome', use: { ...devices['Desktop Chrome'] } },
    { name: 'Mobile Safari', use: { ...devices['iPhone 13'] } },
    { name: 'Mobile Chrome', use: { ...devices['Pixel 7'] } },
    { name: 'Tablet', use: { ...devices['iPad Pro 11'] } },
  ],
});
```

### Library API (Direct Usage)

```javascript
const { chromium, devices } = require('playwright');
const browser = await chromium.launch();
const context = await browser.newContext({ ...devices['iPhone 13'] });
const page = await context.newPage();
await page.goto('https://example.com');
```

## Viewport Emulation

```typescript
// Per-test override
test.use({ viewport: { width: 1600, height: 1200 } });

// Dynamic resize
await page.setViewportSize({ width: 375, height: 667 });

// HiDPI / Retina
const context = await browser.newContext({
  viewport: { width: 2560, height: 1440 },
  deviceScaleFactor: 2,
});
```

## Geolocation

```typescript
// Config-level
export default defineConfig({
  use: {
    geolocation: { longitude: -122.4194, latitude: 37.7749 },
    permissions: ['geolocation'],
  },
});

// Dynamic change
await context.setGeolocation({ longitude: 48.8584, latitude: 2.2945 });
```

## Locale and Timezone

```typescript
// Config-level
export default defineConfig({
  use: { locale: 'en-GB', timezoneId: 'Europe/London' },
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

```typescript
// Dark mode (config, per-test, or dynamic)
test.use({ colorScheme: 'dark' });
await page.emulateMedia({ colorScheme: 'dark' });

// Reduced motion / forced colors / print
await page.emulateMedia({ reducedMotion: 'reduce' });
await page.emulateMedia({ forcedColors: 'active' });
await page.emulateMedia({ media: 'print' });
```

## Permissions

```typescript
// Config-level
export default defineConfig({ use: { permissions: ['notifications'] } });

// Per-context (domain-specific)
await context.grantPermissions(['geolocation'], { origin: 'https://example.com' });
await context.grantPermissions(['notifications', 'camera', 'microphone']);
await context.clearPermissions();
```

**Available permissions**: `geolocation`, `midi`, `midi-sysex`, `notifications`, `camera`, `microphone`, `background-sync`, `ambient-light-sensor`, `accelerometer`, `gyroscope`, `magnetometer`, `accessibility-events`, `clipboard-read`, `clipboard-write`, `payment-handler`

## Offline Mode and JavaScript Disabled

```typescript
// Offline
await context.setOffline(true);

// No JS
test.use({ javaScriptEnabled: false });
```

## User Agent Override

```typescript
test.use({ userAgent: 'Custom Bot/1.0' });
```

## Recipes

### Responsive Breakpoint Testing

```typescript
const breakpoints = [
  { name: 'mobile-sm', width: 320, height: 568 },
  { name: 'mobile-md', width: 375, height: 667 },
  { name: 'tablet', width: 768, height: 1024 },
  { name: 'laptop', width: 1024, height: 768 },
  { name: 'desktop', width: 1280, height: 800 },
  { name: 'desktop-lg', width: 1920, height: 1080 },
];

for (const bp of breakpoints) {
  test(`layout at ${bp.name}`, async ({ browser }) => {
    const context = await browser.newContext({ viewport: { width: bp.width, height: bp.height } });
    const page = await context.newPage();
    await page.goto('https://example.com');
    await expect(page).toHaveScreenshot(`${bp.name}.png`);
    await context.close();
  });
}
```

### Multi-Device Parallel Testing

```typescript
const testDevices = [
  { name: 'iPhone 13', device: devices['iPhone 13'] },
  { name: 'Pixel 7', device: devices['Pixel 7'] },
  { name: 'iPad Pro 11', device: devices['iPad Pro 11'] },
  { name: 'Desktop', device: { viewport: { width: 1280, height: 720 } } },
];

for (const { name, device } of testDevices) {
  test.describe(name, () => {
    test.use({ ...device });
    test('homepage loads', async ({ page }) => {
      await page.goto('https://example.com');
      await page.waitForLoadState('networkidle');
    });
  });
}
```

### Touch Gesture Testing

```javascript
const context = await browser.newContext({ ...devices['iPhone 13'], hasTouch: true });
const page = await context.newPage();
await page.goto('https://example.com');
await page.tap('.button');
await page.touchscreen.tap(200, 300);
```

### Network Condition Emulation (Chromium only, via CDP)

```javascript
const cdpSession = await page.context().newCDPSession(page);

// Slow 3G
await cdpSession.send('Network.emulateNetworkConditions', {
  offline: false,
  downloadThroughput: (500 * 1024) / 8,
  uploadThroughput: (500 * 1024) / 8,
  latency: 400,
});
```

### Dark Mode Visual Regression

```typescript
for (const scheme of ['light', 'dark'] as const) {
  test(`visual regression (${scheme})`, async ({ browser }) => {
    const context = await browser.newContext({ colorScheme: scheme, viewport: { width: 1280, height: 720 } });
    const page = await context.newPage();
    await page.goto('https://example.com');
    await expect(page).toHaveScreenshot(`homepage-${scheme}.png`);
    await context.close();
  });
}
```

## Integration with aidevops Tools

**With Chrome DevTools MCP**: Combine device emulation with performance auditing — navigate in mobile emulation, then connect `npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222` for Lighthouse mobile audit.

**With Stagehand (Natural Language + Device)**:

```javascript
const stagehand = new Stagehand({ env: 'LOCAL', browserOptions: { ...devices['iPhone 13'] } });
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
