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

100+ built-in descriptors (`viewport`, `userAgent`, `deviceScaleFactor`, `isMobile`, `hasTouch`). Landscape variant: append `landscape` (e.g., `devices['iPhone 13 landscape']`).

List all: `node -e "const { devices } = require('playwright'); console.log(Object.keys(devices).join('\n'))"`

| Category | Examples | Viewport | Scale | Mobile |
|----------|----------|----------|-------|--------|
| Desktop | Chrome, Firefox, Safari, Edge | 1280×720 | 1 | No |
| iPhone | 13/14/15, Pro Max | 390×844, 428–430×926–932 | 3 | Yes |
| iPad | gen7, Mini, Pro 11 | 810×1080, 768×1024, 834×1194 | 2 | Yes |
| Android | Pixel 5/7, Galaxy S8/S9+/Tab S4 | 360–412×740–915 | 2.25–4.5 | Yes |

## Configuration

```typescript
// playwright.config.ts — test runner
import { defineConfig, devices } from '@playwright/test';
export default defineConfig({
  projects: [
    { name: 'Desktop Chrome', use: { ...devices['Desktop Chrome'] } },
    { name: 'Mobile Safari',  use: { ...devices['iPhone 13'] } },
    { name: 'Mobile Chrome',  use: { ...devices['Pixel 7'] } },
    { name: 'Tablet',         use: { ...devices['iPad Pro 11'] } },
  ],
});

// Library API
const { chromium, devices } = require('playwright');
const ctx = await (await chromium.launch()).newContext({ ...devices['iPhone 13'] });
await (await ctx.newPage()).goto('https://example.com');
```

## Emulation Options

```typescript
// Viewport / HiDPI
test.use({ viewport: { width: 1600, height: 1200 } });
await page.setViewportSize({ width: 375, height: 667 });
await browser.newContext({ viewport: { width: 2560, height: 1440 }, deviceScaleFactor: 2 });

// Geolocation
use: { geolocation: { longitude: -122.4194, latitude: 37.7749 }, permissions: ['geolocation'] }
await context.setGeolocation({ longitude: 48.8584, latitude: 2.2945 });

// Locale / Timezone
use: { locale: 'en-GB', timezoneId: 'Europe/London' }

// Color scheme / media
await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce', forcedColors: 'active', media: 'print' });

// Permissions
await context.grantPermissions(['geolocation'], { origin: 'https://example.com' });
await context.clearPermissions();

// Offline / JS / User Agent
await context.setOffline(true);
test.use({ javaScriptEnabled: false, userAgent: 'Custom Bot/1.0' });

// Touch
const ctx = await browser.newContext({ ...devices['iPhone 13'], hasTouch: true });
await page.tap('.button');
await page.touchscreen.tap(200, 300);
```

**Permissions**: `geolocation`, `midi`, `midi-sysex`, `notifications`, `camera`, `microphone`, `background-sync`, `ambient-light-sensor`, `accelerometer`, `gyroscope`, `magnetometer`, `accessibility-events`, `clipboard-read`, `clipboard-write`, `payment-handler`

**Locale/timezone pairs**: `en-US`/`America/Los_Angeles`, `en-US`/`America/New_York`, `en-GB`/`Europe/London`, `de-DE`/`Europe/Berlin`, `fr-FR`/`Europe/Paris`, `ja-JP`/`Asia/Tokyo`, `zh-CN`/`Asia/Shanghai`, `hi-IN`/`Asia/Kolkata`, `pt-BR`/`America/Sao_Paulo`, `en-AU`/`Australia/Sydney`

## Recipes

### Responsive Breakpoint Testing

Breakpoints: `mobile-sm` 320×568, `mobile-md` 375×667, `tablet` 768×1024, `laptop` 1024×768, `desktop` 1280×800, `desktop-lg` 1920×1080.

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

### Network Throttling (Chromium/CDP only)

```typescript
const cdp = await page.context().newCDPSession(page);
await cdp.send('Network.emulateNetworkConditions', {
  offline: false, downloadThroughput: (500 * 1024) / 8,
  uploadThroughput: (500 * 1024) / 8, latency: 400, // Slow 3G
});
```

### Dark Mode Visual Regression

```typescript
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

## Integration

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
