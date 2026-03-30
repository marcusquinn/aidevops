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

- **Docs**: https://playwright.dev/docs/emulation
- **Device registry**: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/deviceDescriptorsSource.json
- **Install**: `npm install playwright` or `@playwright/test`
- **Capabilities**: device presets, viewport/screen, user agent, touch (`hasTouch`, `isMobile`), geolocation, locale/timezone, permissions, color scheme, reduced motion, forced colors, offline, JS disabled, HiDPI/Retina
- **When to use**: responsive layouts, mobile behavior, touch, geolocation, locale, dark mode. Complements Maestro (t096) / iOS Simulator MCP (t097) for web-based mobile testing.

<!-- AI-CONTEXT-END -->

## Device Presets

100+ built-in descriptors. Each includes `viewport`, `userAgent`, `deviceScaleFactor`, `isMobile`, `hasTouch`. Landscape variants: `devices['iPhone 13 landscape']`.

```bash
node -e "const { devices } = require('playwright'); console.log(Object.keys(devices).join('\n'))"
```

| Device | Viewport | Scale | Mobile |
|--------|----------|-------|--------|
| Desktop Chrome/Firefox/Safari/Edge | 1280×720 | 1 | No |
| iPhone 13/14/15 | 390×844 | 3 | Yes |
| iPhone 13/14/15 Pro Max | 428–430×926–932 | 3 | Yes |
| iPad gen7 / Mini / Pro 11 | 810×1080 / 768×1024 / 834×1194 | 2 | Yes |
| Pixel 5 / Pixel 7 | 393×851 / 412×915 | 2.75 / 2.625 | Yes |
| Galaxy S8 / S9+ / Tab S4 | 360×740 / 320×658 / 712×1138 | 3 / 4.5 / 2.25 | Yes |

## Configuration

### Test Runner (`playwright.config.ts`)

```typescript
import { defineConfig, devices } from '@playwright/test';
export default defineConfig({
  projects: [
    { name: 'Desktop Chrome', use: { ...devices['Desktop Chrome'] } },
    { name: 'Mobile Safari',  use: { ...devices['iPhone 13'] } },
    { name: 'Mobile Chrome',  use: { ...devices['Pixel 7'] } },
    { name: 'Tablet',         use: { ...devices['iPad Pro 11'] } },
  ],
});
```

### Library API

```javascript
const { chromium, devices } = require('playwright');
const ctx = await (await chromium.launch()).newContext({ ...devices['iPhone 13'] });
await (await ctx.newPage()).goto('https://example.com');
```

## Emulation Options

```typescript
// Viewport
test.use({ viewport: { width: 1600, height: 1200 } });
await page.setViewportSize({ width: 375, height: 667 });
await browser.newContext({ viewport: { width: 2560, height: 1440 }, deviceScaleFactor: 2 }); // HiDPI

// Geolocation
use: { geolocation: { longitude: -122.4194, latitude: 37.7749 }, permissions: ['geolocation'] }
await context.setGeolocation({ longitude: 48.8584, latitude: 2.2945 });

// Locale / Timezone
use: { locale: 'en-GB', timezoneId: 'Europe/London' }

// Color scheme / media
await page.emulateMedia({ colorScheme: 'dark' | 'light', reducedMotion: 'reduce', forcedColors: 'active', media: 'print' });

// Permissions
use: { permissions: ['notifications'] }
await context.grantPermissions(['geolocation'], { origin: 'https://example.com' });
await context.grantPermissions(['notifications', 'camera', 'microphone']);
await context.clearPermissions();

// Offline / JS / User Agent
await context.setOffline(true);
test.use({ javaScriptEnabled: false, userAgent: 'Custom Bot/1.0' });
```

**Permission values**: `geolocation`, `midi`, `midi-sysex`, `notifications`, `camera`, `microphone`, `background-sync`, `ambient-light-sensor`, `accelerometer`, `gyroscope`, `magnetometer`, `accessibility-events`, `clipboard-read`, `clipboard-write`, `payment-handler`

**Common locale/timezone combinations:**

| Market | Locale | Timezone |
|--------|--------|----------|
| US West / East | `en-US` | `America/Los_Angeles` / `America/New_York` |
| UK / Germany / France | `en-GB` / `de-DE` / `fr-FR` | `Europe/London` / `Europe/Berlin` / `Europe/Paris` |
| Japan / China / India | `ja-JP` / `zh-CN` / `hi-IN` | `Asia/Tokyo` / `Asia/Shanghai` / `Asia/Kolkata` |
| Brazil / Australia | `pt-BR` / `en-AU` | `America/Sao_Paulo` / `Australia/Sydney` |

## Recipes

### Responsive Breakpoint Testing

Standard breakpoints: `mobile-sm` 320×568, `mobile-md` 375×667, `tablet` 768×1024, `laptop` 1024×768, `desktop` 1280×800, `desktop-lg` 1920×1080.

```typescript
for (const bp of breakpoints) {
  test(`layout at ${bp.name}`, async ({ browser }) => {
    const ctx = await browser.newContext({ viewport: { width: bp.width, height: bp.height } });
    const page = await ctx.newPage();
    await page.goto('https://example.com');
    await expect(page).toHaveScreenshot(`${bp.name}.png`);
    await ctx.close();
  });
}
```

### Multi-Device Parallel Testing

```typescript
for (const { name, device } of testDevices) {
  test.describe(name, () => {
    test.use({ ...device });
    test('homepage loads', async ({ page }) => {
      await page.goto('https://example.com');
      await page.waitForLoadState('networkidle');
    });
  });
}
// testDevices: [{ name, device }] where device = devices['iPhone 13'] | devices['Pixel 7'] | { viewport: {...} }
```

### Touch, Network, Dark Mode

```typescript
// Touch gestures
const ctx = await browser.newContext({ ...devices['iPhone 13'], hasTouch: true });
await (await ctx.newPage()).tap('.button');
await page.touchscreen.tap(200, 300);

// Network throttling (Chromium/CDP only — Slow 3G)
const cdp = await page.context().newCDPSession(page);
await cdp.send('Network.emulateNetworkConditions', {
  offline: false, downloadThroughput: (500 * 1024) / 8,
  uploadThroughput: (500 * 1024) / 8, latency: 400,
});

// Dark mode visual regression
for (const scheme of ['light', 'dark'] as const) {
  test(`visual regression (${scheme})`, async ({ browser }) => {
    const ctx = await browser.newContext({ colorScheme: scheme, viewport: { width: 1280, height: 720 } });
    const page = await ctx.newPage();
    await page.goto('https://example.com');
    await expect(page).toHaveScreenshot(`homepage-${scheme}.png`);
    await ctx.close();
  });
}
```

## Integration with aidevops Tools

- **Chrome DevTools MCP**: navigate in mobile emulation → `npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222` for Lighthouse mobile audit.
- **Stagehand**: `new Stagehand({ env: 'LOCAL', browserOptions: { ...devices['iPhone 13'] } })` → `stagehand.act('tap the hamburger menu')`.

## Related

- `playwright.md` — core automation (cross-browser, forms, security, API testing)
- `playwright-cli.md` — CLI-first Playwright for AI agents
- `browser-automation.md` — tool selection decision tree
- `browser-benchmark.md` — performance benchmarks
- `pagespeed.md` — PageSpeed Insights integration
- Maestro (t096) — native mobile E2E testing
- iOS Simulator MCP (t097) — iOS simulator interaction
