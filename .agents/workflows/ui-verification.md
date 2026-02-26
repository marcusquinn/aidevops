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

## Design Principles Checklist

Every UI change must be evaluated against these principles. They are not suggestions -- they are quality gates. Check each applicable principle during verification (step 5) and report violations in the verification report (step 6).

### Typography and Readability

| Principle | Rule | How to verify |
|-----------|------|---------------|
| **Maximum paragraph width** | No paragraph text wider than 740px (approximately 75 characters per line) | Inspect `max-width` on text containers; screenshot at desktop-lg to confirm text does not stretch edge-to-edge |
| **Minimum text size** | Body text minimum 16px (1rem). Supplementary text (legal footnotes, captions, timestamps) may use 14px but never smaller. All other text must be 16px or above | Playwright `evaluate()` to check computed `font-size` on all text elements; flag anything below 14px as a violation, anything between 14-16px that is not supplementary |
| **Font family limit** | Maximum 3 font families: (1) headings/titles, (2) body/buttons/forms/blockquotes, (3) code/monospace | Inspect computed `font-family` values across the page; flag any fourth family |
| **Font weight hierarchy** | Use distinct font weights to establish visual hierarchy (e.g., 700 headings, 400 body, 600 labels). Avoid using a single weight for everything | Check that headings are visually heavier than body text in screenshots |
| **Line height** | Line spacing sufficient to prevent text overlap when wrapping. Minimum `line-height: 1.4` for body text, `1.2` for headings | Inspect computed `line-height`; verify wrapped text does not collide in screenshots |
| **Letter spacing** | Letter spacing adequate to prevent character overlap. Default is usually fine; verify custom fonts do not collapse characters | Visual check in screenshots, especially at small sizes and bold weights |
| **Widow and orphan control** | Avoid single words on a final line (widows) or single lines at the top of a column (orphans). Use `text-wrap: balance` or `text-wrap: pretty` where supported | Visual check in screenshots at multiple widths; verify headings and short paragraphs do not leave isolated words |

### Layout and Spacing

| Principle | Rule | How to verify |
|-----------|------|---------------|
| **Consistent padding** | Use a spacing scale (e.g., 4/8/12/16/24/32/48px). Padding should be consistent between similar elements | Inspect padding values; flag inconsistent spacing between sibling elements |
| **Adequate padding for readability** | Text containers must have sufficient internal padding -- text should never touch container edges | Screenshot check; verify text has breathing room inside cards, sections, and containers |
| **Consistent alignment** | Elements within a section should share alignment (left-aligned, centred, or right-aligned). Do not mix alignment arbitrarily | Visual check in screenshots; verify form labels, headings, and body text align consistently |
| **Consistent sizing** | Similar elements (cards, buttons, icons) should be the same size. Avoid arbitrary size variation | Visual check; verify repeated elements are uniform |
| **Logo padding** | Brand logos must have adequate clear space around them -- never crowded by adjacent elements | Screenshot check; verify logo has breathing room in header/nav |
| **Graceful responsive adjustment** | Layout should adapt smoothly across breakpoints, not just snap between fixed layouts. Content should work for varying lengths (short titles, long titles, empty states) | Test with different content lengths at each breakpoint; verify no overflow, truncation, or collapse |

### Interaction and Accessibility

| Principle | Rule | How to verify |
|-----------|------|---------------|
| **Finger-friendly touch targets** | All interactive elements minimum 44x44px touch target area (per Apple/Google HIG and WCAG 2.5.5 AAA). WCAG 2.5.8 AA minimum is 24x24px -- aim for 44px, never below 24px. Adequate spacing between adjacent targets to prevent mis-taps | Playwright `evaluate()` to measure element bounding boxes on mobile device emulation |
| **Hover/rollover state changes** | All clickable elements must have a visible hover state change (colour, underline, shadow, scale) to signal interactivity | Playwright `hover()` + screenshot comparison; verify visual change on buttons, links, cards |
| **Link text styling in paragraphs** | Links within paragraph text must be bold, underlined, and use a distinct colour to be identifiable without relying on colour alone | Inspect computed styles on `<a>` elements within `<p>` tags; verify `font-weight`, `text-decoration`, and `color` differ from surrounding text |
| **Meaningful alt and title attributes** | All images must have descriptive `alt` text that serves the user first -- describe what the image conveys, not keyword-stuffed SEO text. Brand and subject keywords may be included naturally where they are genuinely descriptive. Decorative images use `alt=""`. Use `aria-label` or `aria-labelledby` on interactive elements (preferred over `title`, which is inconsistently announced by screen readers) | Playwright `evaluate()` to audit all `<img>` elements for `alt`; flag empty or generic values like "image", "photo", or "logo" |
| **Information-relevant icons** | Icons should reinforce meaning, not decorate. Every icon should be understandable without its label, or be paired with a text label | Visual check; verify icons match their associated action or content |
| **Scroll wheel behaviour** | Mouse scroll wheel must work as expected on all scrollable areas. Custom scroll containers, modals, carousels, and overflow regions must not trap, hijack, or block scroll events. Page scroll must not be intercepted by nested scrollable elements unexpectedly | Playwright `mouse.wheel()` on page body and any custom scroll containers; verify scroll position changes as expected and no scroll-trapping occurs |

### Colour and Theming

| Principle | Rule | How to verify |
|-----------|------|---------------|
| **Informational colour coding** | Use conventional colour associations (red=error/danger, amber=warning, green=success, blue=info). Colours should be distinct from each other and sympathetic to brand colours in hue and tone | Visual check; verify status colours are distinguishable and follow conventions |
| **Text highlighting for both modes** | Any text highlighting (selection, search results, emphasis backgrounds) must maintain adequate contrast in both light and dark modes | Test with `colorScheme: 'light'` and `colorScheme: 'dark'`; run contrast check on highlighted elements |
| **Brand logo links to home** | Brand logos in navigation areas must link to the home page (`/` or site root) | Playwright `evaluate()` to verify logo `<a>` element `href` is `/` or the site root URL |

### Information Architecture

| Principle | Rule | How to verify |
|-----------|------|---------------|
| **Clear information hierarchy** | Visual hierarchy must be established through layout position, font size, font weight, and whitespace -- not colour alone. The most important content should be the most visually prominent | Screenshot check; verify primary content/CTA is the first thing the eye is drawn to |
| **Standard naming conventions** | CSS classes, component names, and design tokens should follow clear, hierarchical naming (e.g., BEM, utility-first, or design-token conventions). Names should be descriptive and consider future extensibility | Code review; verify naming is consistent and self-documenting |

### Usability (Mom Test)

After all technical checks pass, evaluate the page against the Mom Test heuristic (see `seo/mom-test-ux.md`):

- **Clarity**: Can a non-technical user understand what the page wants them to do within 10 seconds?
- **Simplicity**: Is there unnecessary complexity, clutter, or cognitive load?
- **Consistency**: Do similar elements look and behave the same way across pages?
- **Feedback**: Does every interaction produce a visible response?
- **Discoverability**: Can users find what they need without instructions?
- **Forgiveness**: Can users recover from mistakes easily?

If the page fails any Mom Test principle at severity S1 (blocker) or S2 (major), it must be fixed before the task is considered complete.

## Quick Verification (Minimal)

For small CSS tweaks where full verification is overkill, run the minimum:

```bash
# 1. Screenshot at 3 sizes (mobile, tablet, desktop)
# 2. Check for console errors
# 3. Run contrast check on affected components
# 4. Spot-check: paragraph width, text size, touch targets
```

The full workflow (6 steps + design principles) is for significant layout changes, new components, or responsive redesigns.

## Integration with Build Workflow

This workflow slots into Build+ steps 8-9 (Testing and Validate):

1. Steps 1-7 proceed as normal
2. **Step 8 (Testing)**: If task involves UI changes, run UI Verification steps 1-5 alongside unit/integration tests. Check applicable design principles.
3. **Step 9 (Validate)**: Include UI verification report as evidence. "Browser (UI)" in the verification hierarchy means *actual browser screenshots*, not self-assessment. Report any design principle violations with severity.

## When to Skip

- Backend-only changes (no UI impact)
- Documentation-only changes
- CI/CD configuration changes
- Database migrations (unless they affect displayed data)
- API-only changes (unless they affect rendered content)

When in doubt, run at least the quick verification (3 screenshots + console error check + design principle spot-check). It takes under 30 seconds and catches layout regressions that code review cannot.

## Related

- `tools/browser/playwright-emulation.md` -- Device presets and emulation configuration
- `tools/browser/chrome-devtools.md` -- Browser debugging and performance inspection
- `tools/accessibility/accessibility.md` -- WCAG compliance testing
- `tools/browser/browser-automation.md` -- Tool selection decision tree
- `tools/browser/pagespeed.md` -- Performance testing (includes accessibility score)
