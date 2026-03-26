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

**Purpose**: Verify UI/layout/design changes across devices, catch browser errors, validate accessibility.
**Trigger**: CSS, layout, responsive design, UI components, visual changes, or task descriptions containing: layout, responsive, design, UI, UX, visual, styling, CSS.
**Principle**: Never self-assess "looks good" — use real browser verification with evidence.

<!-- AI-CONTEXT-END -->

## Workflow

### 1. Capture Baseline

> **Screenshot size limit**: NEVER use `fullPage: true` for AI vision review — exceeds 8000px, hard-crashes the session. Viewport-sized only. See `prompts/build.txt` "Screenshot Size Limits".

```typescript
import { chromium, devices } from 'playwright';
const standardDevices = [
  { name: 'mobile',     config: devices['iPhone 14'] },
  { name: 'tablet',     config: devices['iPad Pro 11'] },
  { name: 'desktop',    config: { viewport: { width: 1280, height: 800 } } },
  { name: 'desktop-lg', config: { viewport: { width: 1920, height: 1080 } } },
];
const browser = await chromium.launch();
for (const { name, config } of standardDevices) {
  const ctx = await browser.newContext({ ...config });
  const page = await ctx.newPage();
  await page.goto(targetUrl);
  await page.waitForLoadState('networkidle');
  await page.screenshot({ path: `/tmp/ui-verify/before-${name}.png` });
  await ctx.close();
}
await browser.close();
```

### 2. Make Changes

Implement UI/layout changes as normal.

### 3. Multi-Device Screenshots

Capture after-state using the same device list (replace `before-` with `after-`).

**Standard breakpoints:**

| Name | Width | Height | Device |
|------|-------|--------|--------|
| `mobile` | 390 | 844 | iPhone 14 |
| `tablet` | 834 | 1194 | iPad Pro 11 |
| `desktop` | 1280 | 800 | Standard laptop |
| `desktop-lg` | 1920 | 1080 | Full HD monitor |

**Edge cases (responsive-critical work):** `mobile-sm` 320×568 (iPhone SE), `mobile-landscape` 844×390, `tablet-landscape` 1194×834.

### 4. Browser Error Check

```typescript
for (const { name, config } of standardDevices) {
  const ctx = await browser.newContext({ ...config });
  const page = await ctx.newPage();
  const errors = [], failed = [];
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('requestfailed', r => failed.push({ url: r.url(), err: r.failure()?.errorText }));
  await page.goto(targetUrl);
  await page.waitForLoadState('networkidle');
  if (errors.length) console.error(`[${name}] errors:`, errors);
  if (failed.length) console.error(`[${name}] failed:`, failed);
  await ctx.close();
}
```

**With Chrome DevTools MCP:** `captureConsole({logLevel:'error'})`, `analyzeCSSCoverage({reportUnused:true})`, `monitorNetwork({filters:[...]})`.

**Check for**: JS errors, failed requests (404s, CORS), CSS warnings, mixed content, deprecation warnings, layout shift (CLS).

### 5. Accessibility Verification

Not optional for UI changes.

```bash
~/.aidevops/agents/scripts/accessibility-helper.sh audit <url>
~/.aidevops/agents/scripts/accessibility-helper.sh playwright-contrast <url>
~/.aidevops/agents/scripts/accessibility-audit-helper.sh axe <url>
```

| Check | Tool | WCAG |
|-------|------|------|
| Colour contrast | `playwright-contrast` | 1.4.3 AA |
| Keyboard navigation | Playwright `page.keyboard` | 2.1.1 A |
| Focus visibility | Screenshot with `:focus` | 2.4.7 AA |
| Heading structure | axe-core / pa11y | 1.3.1 A |
| Touch targets | Device emulation | 2.5.8 AA |
| Text scaling | Viewport at 200% zoom | 1.4.4 AA |

**Dark mode / reduced motion:** Test `colorScheme: 'light'` and `'dark'` (screenshot each); test `reducedMotion: 'reduce'` (verify animations disabled).

### 6. Compare and Report

Report format:

```
## UI Verification Report
### Screenshots — mobile/tablet/desktop/desktop-lg: [before] [after] -- <what changed>
### Browser Errors — <none or list>
### Accessibility — contrast pass/fail, keyboard pass/fail, axe violations
### Issues Found — [device] <description> [S1/S2/S3]
```

---

## Design Principles Checklist

Quality gates — not suggestions. Check applicable principles during step 5; report violations as `[S1/S2/S3] <principle> — <description>`.

### Severity

| Level | Definition | Action |
|-------|------------|--------|
| **S1 Blocker** | Prevents use or legal/compliance risk (invisible text, unreachable keyboard element, missing `alt`, touch target <24px) | Fix before complete |
| **S2 Major** | Significantly degrades usability/brand (paragraph >740px, body text <16px, missing hover state, logo not linking home) | Fix before complete |
| **S3 Minor** | Noticeable but doesn't block use (orphaned word, fourth font family, inconsistent icon sizing) | Fix if low effort; else log |

### Typography

| Rule | How to verify |
|------|---------------|
| Paragraph width ≤740px (~75 chars/line) | Inspect `max-width`; screenshot at desktop-lg |
| Body text ≥16px; supplementary (captions, footnotes) ≥14px; nothing smaller | Playwright `evaluate()` computed `font-size` on all text elements |
| Max 3 font families: headings, body/buttons/forms, code/monospace | Inspect computed `font-family`; flag 4th family |
| Distinct font weights for hierarchy (e.g., 700 headings, 400 body, 600 labels) | Verify headings visually heavier than body in screenshots |
| Line height ≥1.4 body, ≥1.2 headings | Inspect computed `line-height`; verify no text collision |
| No character overlap from letter spacing; verify custom fonts at small sizes/bold | Visual check in screenshots |
| No single words on final line; use `text-wrap: balance`/`pretty` | Visual check at multiple widths |

### Layout and Spacing

| Rule | How to verify |
|------|---------------|
| Spacing scale (4/8/12/16/24/32/48px); consistent between similar elements | Inspect padding; flag inconsistent sibling spacing |
| Text never touches container edges | Screenshot; verify breathing room in cards/sections |
| Elements within a section share alignment; no arbitrary mixing | Visual check; verify form labels/headings/body align |
| Similar elements (cards, buttons, icons) same size | Visual check; verify repeated elements are uniform |
| Brand logos have adequate clear space | Screenshot; verify logo has breathing room in header/nav |
| Smooth adaptation across breakpoints; works for varying content lengths | Test with short/long content at each breakpoint; verify no overflow/truncation |

### Interaction and Accessibility

| Rule | How to verify |
|------|---------------|
| Touch targets min 44×44px (aim); never below 24×24px; adequate spacing between targets | Playwright `evaluate()` bounding boxes on mobile emulation |
| All clickable elements have visible hover change (colour, underline, shadow, scale) | Playwright `hover()` + screenshot comparison |
| Links in paragraphs: bold, underlined, distinct colour (not colour-only) | Inspect computed styles on `<a>` within `<p>` |
| Descriptive `alt` on informational images; `alt=""` on decorative; `aria-label`/`aria-labelledby` on interactive elements (preferred over `title`) | Playwright `evaluate()` audit all `<img>`; flag empty/generic values |
| Icons reinforce meaning; understandable without label or paired with text | Visual check |
| Scroll wheel works on all scrollable areas; no scroll trapping/hijacking | Playwright `mouse.wheel()` on page body and custom scroll containers |

### Colour and Theming

- Conventional colour associations: red=error, amber=warning, green=success, blue=info — visual check
- Text highlighting adequate contrast in both light/dark modes — test both `colorScheme` values
- Brand logo in nav links to `/` or site root — Playwright `evaluate()` logo `<a>` href

### Information Architecture

- Visual hierarchy via layout, size, weight, whitespace — not colour alone; primary CTA most prominent — screenshot check
- CSS classes, component names, design tokens follow consistent convention (BEM, utility-first, or token-based) — code review

### Usability (Mom Test)

Evaluate against `seo/mom-test-ux.md` after technical checks: Clarity (goal clear in 10s?), Simplicity (no clutter?), Consistency (same elements behave same?), Feedback (interactions produce response?), Discoverability (findable without instructions?), Forgiveness (recoverable from mistakes?). S1/S2 failures must be fixed before complete.

---

## Quick Verification (Minimal)

For small CSS tweaks: screenshot at 3 sizes → console errors → contrast check → spot-check paragraph width/text size/touch targets. Full workflow for significant layout changes, new components, or responsive redesigns.

## Integration with Build Workflow

- **Step 8 (Testing)**: Run UI Verification steps 1–5 alongside unit/integration tests; check applicable design principles.
- **Step 9 (Validate)**: Include UI verification report as evidence. "Browser (UI)" means *actual browser screenshots*, not self-assessment.

## When to Skip

Backend-only, docs-only, CI/CD config, DB migrations (unless affecting displayed data), API-only (unless affecting rendered content). When in doubt, run quick verification — under 30 seconds.

## Related

- `tools/browser/playwright-emulation.md` — Device presets and emulation configuration
- `tools/browser/chrome-devtools.md` — Browser debugging and performance inspection
- `tools/accessibility/accessibility.md` — WCAG compliance testing
- `tools/browser/browser-automation.md` — Tool selection decision tree
- `tools/browser/pagespeed.md` — Performance testing (includes accessibility score)
