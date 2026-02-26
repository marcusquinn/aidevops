---
description: Visual verification workflow for UI, layout, and design changes
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

# UI Verification Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Verify UI/layout/design changes across devices, catch browser errors, and validate accessibility
- **Trigger**: Any task involving CSS, layout, responsive design, UI components, or visual changes
- **Tools**: Playwright device emulation, Chrome DevTools MCP, accessibility helpers
- **Principle**: Never self-assess "looks good" -- use real browser verification with evidence

**When this workflow applies** (detect from task description, file changes, or TODO brief):
- CSS/SCSS/Tailwind changes (stylesheets, utility classes, theme tokens)
- Component layout changes (flexbox, grid, positioning, spacing)
- Responsive design work (breakpoints, media queries, container queries)
- New UI components or pages
- Design system changes (typography, colours, spacing scale)
- Dark mode / theme changes
- Any task description containing: layout, responsive, design, UI, UX, visual, styling, CSS

<!-- AI-CONTEXT-END -->

## Workflow

### 1. Capture Baseline (Before Changes)

Before making any visual changes, capture the current state for comparison:

```typescript
import { chromium, devices } from 'playwright';

const standardDevices = [
  { name: 'mobile', config: devices['iPhone 14'] },
  { name: 'tablet', config: devices['iPad Pro 11'] },
  { name: 'desktop', config: { viewport: { width: 1280, height: 800 } } },
  { name: 'desktop-lg', config: { viewport: { width: 1920, height: 1080 } } },
];

const browser = await chromium.launch();
for (const { name, config } of standardDevices) {
  const context = await browser.newContext({ ...config });
  const page = await context.newPage();
  await page.goto(targetUrl);
  await page.waitForLoadState('networkidle');
  await page.screenshot({ path: `/tmp/ui-verify/before-${name}.png`, fullPage: true });
  await context.close();
}
await browser.close();
```

### 2. Make Changes

Implement the UI/layout changes as normal (Build Workflow steps 5-6).

### 3. Multi-Device Screenshot Verification

After changes, capture the same pages across all standard breakpoints:

```typescript
// Same device list as baseline -- capture "after" screenshots
for (const { name, config } of standardDevices) {
  const context = await browser.newContext({ ...config });
  const page = await context.newPage();
  await page.goto(targetUrl);
  await page.waitForLoadState('networkidle');
  await page.screenshot({ path: `/tmp/ui-verify/after-${name}.png`, fullPage: true });
  await context.close();
}
```

**Standard breakpoints** (minimum set -- add project-specific breakpoints as needed):

| Name | Width | Height | Device | Covers |
|------|-------|--------|--------|--------|
| `mobile` | 390 | 844 | iPhone 14 | Small phones |
| `tablet` | 834 | 1194 | iPad Pro 11 | Tablets, small laptops |
| `desktop` | 1280 | 800 | Standard laptop | Most desktop users |
| `desktop-lg` | 1920 | 1080 | Full HD monitor | Large screens |

For responsive-critical work, also test edge cases:

| Name | Width | Height | Why |
|------|-------|--------|-----|
| `mobile-sm` | 320 | 568 | Smallest supported (iPhone SE) |
| `mobile-landscape` | 844 | 390 | Landscape phone (nav/header issues) |
| `tablet-landscape` | 1194 | 834 | Landscape tablet |

### 4. Browser Error Check (Chrome DevTools)

Use Chrome DevTools MCP to catch JavaScript errors, failed network requests, and rendering issues:

```javascript
// Capture console errors across all device sizes
for (const { name, config } of standardDevices) {
  const context = await browser.newContext({ ...config });
  const page = await context.newPage();

  // Collect console errors
  const errors = [];
  page.on('console', msg => {
    if (msg.type() === 'error') errors.push(msg.text());
  });

  // Collect failed requests
  const failedRequests = [];
  page.on('requestfailed', request => {
    failedRequests.push({ url: request.url(), error: request.failure()?.errorText });
  });

  await page.goto(targetUrl);
  await page.waitForLoadState('networkidle');

  if (errors.length > 0) {
    console.error(`[${name}] Console errors:`, errors);
  }
  if (failedRequests.length > 0) {
    console.error(`[${name}] Failed requests:`, failedRequests);
  }

  await context.close();
}
```

**With Chrome DevTools MCP** (when available as an MCP tool):

```javascript
// Comprehensive page analysis per device
await chromeDevTools.captureConsole({
  url: targetUrl,
  logLevel: 'error',
  duration: 10000
});

// CSS coverage -- find unused CSS
await chromeDevTools.analyzeCSSCoverage({
  url: targetUrl,
  reportUnused: true
});

// Network monitoring -- catch failed loads
await chromeDevTools.monitorNetwork({
  url: targetUrl,
  filters: ['xhr', 'fetch', 'document', 'stylesheet', 'script', 'image'],
  captureHeaders: true
});
```

**What to check for:**
- JavaScript errors (uncaught exceptions, failed imports)
- Failed network requests (404s for assets, CORS errors)
- CSS warnings (invalid properties, failed `@import`)
- Mixed content warnings (HTTP resources on HTTPS pages)
- Deprecation warnings (APIs scheduled for removal)
- Layout shift warnings (CLS-related)

### 5. Accessibility Verification

Run accessibility checks on affected pages. This is not optional for UI changes.

```bash
# Quick accessibility audit (Lighthouse + pa11y)
~/.aidevops/agents/scripts/accessibility-helper.sh audit <url>

# Contrast check for all visible text elements
~/.aidevops/agents/scripts/accessibility-helper.sh playwright-contrast <url>

# axe-core standalone scan
~/.aidevops/agents/scripts/accessibility-audit-helper.sh axe <url>
```

**Minimum checks for any UI change:**

| Check | Tool | WCAG | Why |
|-------|------|------|-----|
| Colour contrast | `playwright-contrast` or `contrast` | 1.4.3 (AA) | Text must be readable |
| Keyboard navigation | Playwright `page.keyboard` | 2.1.1 (A) | All interactive elements reachable |
| Focus visibility | Screenshot with `:focus` | 2.4.7 (AA) | Focus indicator must be visible |
| Heading structure | axe-core / pa11y | 1.3.1 (A) | Logical heading hierarchy |
| Touch targets | Device emulation | 2.5.8 (AA) | Minimum 24x24px (44x44px recommended) |
| Text scaling | Viewport at 200% zoom | 1.4.4 (AA) | Content readable at 200% |

**For dark mode / theme changes, also check:**

```typescript
// Test both colour schemes
for (const scheme of ['light', 'dark'] as const) {
  const context = await browser.newContext({
    colorScheme: scheme,
    viewport: { width: 1280, height: 800 },
  });
  const page = await context.newPage();
  await page.goto(targetUrl);
  await page.screenshot({ path: `/tmp/ui-verify/${scheme}-mode.png` });
  await context.close();
}

// Test reduced motion preference
const context = await browser.newContext({ reducedMotion: 'reduce' });
const page = await context.newPage();
await page.goto(targetUrl);
// Verify animations are disabled/reduced
```

### 6. Compare and Report

Compare before/after screenshots. Report findings with evidence:

```text
## UI Verification Report

### Screenshots (before/after per device)
- mobile: [before] [after] -- hamburger menu alignment fixed
- tablet: [before] [after] -- sidebar now collapses correctly
- desktop: [before] [after] -- no visual change (expected)
- desktop-lg: [before] [after] -- grid fills available space

### Browser Errors
- None found across all device sizes

### Accessibility
- Contrast: all text passes WCAG AA (4.5:1 minimum)
- Keyboard: all interactive elements reachable via Tab
- axe-core: 0 violations

### Issues Found
- [mobile] Footer overlaps content at 320px width -- needs fix
- [tablet-landscape] Navigation dropdown clips at right edge
```

## Quick Verification (Minimal)

For small CSS tweaks where full verification is overkill, run the minimum:

```bash
# 1. Screenshot at 3 sizes (mobile, tablet, desktop)
# 2. Check for console errors
# 3. Run contrast check on affected components
```

The full workflow (6 steps) is for significant layout changes, new components, or responsive redesigns.

## Integration with Build Workflow

This workflow slots into Build+ steps 8-9 (Testing and Validate):

1. Steps 1-7 proceed as normal
2. **Step 8 (Testing)**: If task involves UI changes, run UI Verification steps 1-5 alongside unit/integration tests
3. **Step 9 (Validate)**: Include UI verification report as evidence. "Browser (UI)" in the verification hierarchy means *actual browser screenshots*, not self-assessment

## When to Skip

- Backend-only changes (no UI impact)
- Documentation-only changes
- CI/CD configuration changes
- Database migrations (unless they affect displayed data)
- API-only changes (unless they affect rendered content)

When in doubt, run at least the quick verification (3 screenshots + console error check). It takes under 30 seconds and catches layout regressions that code review cannot.

## Related

- `tools/browser/playwright-emulation.md` -- Device presets and emulation configuration
- `tools/browser/chrome-devtools.md` -- Browser debugging and performance inspection
- `tools/accessibility/accessibility.md` -- WCAG compliance testing
- `tools/browser/browser-automation.md` -- Tool selection decision tree
- `tools/browser/pagespeed.md` -- Performance testing (includes accessibility score)
