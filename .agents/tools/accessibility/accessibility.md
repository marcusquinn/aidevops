---
description: Accessibility and contrast testing — WCAG compliance for websites and emails
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
---

# Accessibility & Contrast Testing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `.agents/scripts/accessibility-helper.sh` — Lighthouse, pa11y, Playwright contrast, WAVE API, email, contrast calc
- **Audit Helper**: `.agents/scripts/accessibility-audit-helper.sh` — axe-core, WAVE API, WebAIM contrast, Lighthouse
- **Commands (helper)**: `audit [url]` | `lighthouse [url]` | `pa11y [url]` | `playwright-contrast [url]` | `wave [url]` | `email [file]` | `contrast [fg] [bg]` | `bulk [file]`
- **Commands (audit)**: `axe [url]` | `wave [url]` | `contrast [fg] [bg]` | `compare [url]` | `status`
- **Install**: `accessibility-helper.sh install-deps` or `accessibility-audit-helper.sh install-deps`
- **Standards**: WCAG 2.1 Level A, AA (default), AAA
- **Reports**: `~/.aidevops/reports/accessibility/` and `~/.aidevops/reports/accessibility-audit/`
- **Env vars**: `A11Y_WCAG_LEVEL` / `AUDIT_WCAG_LEVEL` (default `WCAG2AA`), `WAVE_API_KEY`

<!-- AI-CONTEXT-END -->

## Tools Overview

| Tool | Helper | Purpose | Speed | Depth |
|------|--------|---------|-------|-------|
| **Lighthouse** | both | Accessibility score + audit failures | ~15s | Broad (axe-core engine) |
| **pa11y** | helper | WCAG-specific violation reporting | ~10s | Deep (HTML_CodeSniffer) |
| **Playwright contrast** | helper | Computed style analysis for all visible elements | ~5-15s | Every text element |
| **WAVE API** | both | Comprehensive analysis (CSS/JS-rendered) | ~2-5s | Deep (WAVE engine) |
| **@axe-core/cli** | audit | Standalone axe scanner | ~10s | Deep (axe-core direct) |
| **WebAIM Contrast API** | audit | Programmatic colour contrast (no key required) | Instant | AA + AAA levels |
| **Email checker** | helper | HTML email accessibility (static analysis) | <1s | Email-specific rules |
| **Contrast calculator** | helper | WCAG contrast ratio for color pairs | Instant | AA + AAA levels |

## Setup

```bash
.agents/scripts/accessibility-helper.sh install-deps
.agents/scripts/accessibility-audit-helper.sh install-deps

# WAVE API key (optional — register at https://wave.webaim.org/api/register)
aidevops secret set wave-api-key   # encrypted (recommended)
export WAVE_API_KEY="your-key"     # or environment variable
```

## Usage

### Full Audit

Runs Lighthouse + pa11y on desktop and mobile:

```bash
.agents/scripts/accessibility-helper.sh audit https://example.com
```

### Lighthouse

```bash
.agents/scripts/accessibility-helper.sh lighthouse https://example.com         # desktop
.agents/scripts/accessibility-helper.sh lighthouse https://example.com mobile  # mobile
```

Reports: accessibility score (0-100%), failed audits (contrast, ARIA, labels), ARIA validation.

### pa11y WCAG Testing

```bash
.agents/scripts/accessibility-helper.sh pa11y https://example.com           # AA (default)
.agents/scripts/accessibility-helper.sh pa11y https://example.com WCAG2AAA  # AAA
.agents/scripts/accessibility-helper.sh pa11y https://example.com WCAG2A    # A
```

Issues categorised as errors (must fix), warnings (should fix), notices (advisory).

### WAVE API

Evaluates pages after CSS/JS rendering. Requires `WAVE_API_KEY`.

```bash
.agents/scripts/accessibility-helper.sh wave https://example.com    # type 2 (default, 2 credits)
.agents/scripts/accessibility-helper.sh wave https://example.com 3  # + XPath locations (3 credits)
.agents/scripts/accessibility-helper.sh wave https://example.com 4  # + CSS selectors (3 credits)
.agents/scripts/accessibility-helper.sh wave-mobile https://example.com  # 375px viewport
.agents/scripts/accessibility-helper.sh wave-docs alt_missing            # look up WAVE item
.agents/scripts/accessibility-helper.sh wave-credits                     # check remaining credits
```

Report types: 1 = counts only (1 credit), 2 = counts + item details (2 credits), 3/4 = + locations + contrast data (3 credits).

WAVE categories: errors (must fix), contrast errors, alerts (should review), features (positive), structural elements, ARIA usage.

### Contrast Ratio Calculator

```bash
.agents/scripts/accessibility-helper.sh contrast '#333333' '#ffffff'
```

Output: pass/fail for AA normal (4.5:1), AA large (3:1), AAA normal (7:1), AAA large (4.5:1).

### Playwright Contrast Extraction

Renders page headlessly, traverses DOM extracting computed foreground/background colors (resolving transparent backgrounds), font sizes, and weights. Calculates WCAG ratios per element. Per-element output: CSS selector, computed colors, contrast ratio `(L1+0.05)/(L2+0.05)`, AA/AAA pass/fail (SC 1.4.3/1.4.6), large text detection (≥18pt or ≥14pt bold), gradient/image background flags for manual review. Exit codes: 0 = all pass, 1 = failures found, 2 = script error.

```bash
.agents/scripts/accessibility-helper.sh playwright-contrast https://example.com           # summary
.agents/scripts/accessibility-helper.sh playwright-contrast https://example.com json      # JSON
.agents/scripts/accessibility-helper.sh playwright-contrast https://example.com markdown AAA

# Direct script (more options)
node .agents/scripts/accessibility/playwright-contrast.mjs https://example.com --format json --fail-only
node .agents/scripts/accessibility/playwright-contrast.mjs https://example.com --limit 20
```

### Email HTML Accessibility

Checks: `alt` on images (1.1.1), `lang` on `<html>` (3.1.1), `role="presentation"` on layout tables (1.3.1), font size <12px (1.4.4), generic link text (2.4.4), heading structure (1.3.1), color-only indicators (1.4.1).

```bash
.agents/scripts/accessibility-helper.sh email ./newsletter.html
```

Email clients strip most CSS/JS. Key rules: `alt` text on all images; `role="presentation"` on layout tables; `lang` on `<html>`; minimum 14px font size; avoid colour-only indicators; descriptive link text; logical reading order; preheader text for screen readers.

### Bulk Audit

```bash
.agents/scripts/accessibility-helper.sh bulk sites.txt  # one URL per line, # for comments
```

### Audit Helper Commands

```bash
# axe-core (default tags: wcag2a, wcag2aa, best-practice)
.agents/scripts/accessibility-audit-helper.sh axe https://example.com
.agents/scripts/accessibility-audit-helper.sh axe https://example.com wcag2aa,wcag21aa

# WAVE API (requires WAVE_API_KEY)
.agents/scripts/accessibility-audit-helper.sh wave https://example.com

# WebAIM contrast (no key required)
.agents/scripts/accessibility-audit-helper.sh contrast '#333333' '#ffffff'

# Multi-engine comparison
.agents/scripts/accessibility-audit-helper.sh compare https://example.com

# Check installed engines
.agents/scripts/accessibility-audit-helper.sh status
```

## WCAG 2.1 Quick Reference

| Level | Criterion | Description |
|-------|-----------|-------------|
| **A** | 1.1.1 | Non-text content has text alternatives |
| **A** | 1.3.1 | Information and relationships are programmatically determinable |
| **A** | 1.4.1 | Color is not the only means of conveying information |
| **A** | 2.1.1 | All functionality is keyboard accessible |
| **A** | 2.4.1 | Skip navigation mechanism available |
| **A** | 4.1.1 | HTML validates without significant errors |
| **A** | 4.1.2 | Name, role, value for all UI components |
| **AA** | 1.4.3 | Contrast ratio at least 4.5:1 (normal text) |
| **AA** | 1.4.4 | Text can be resized up to 200% without loss |
| **AA** | 1.4.5 | Text is used instead of images of text |
| **AA** | 2.4.6 | Headings and labels describe topic or purpose |
| **AA** | 2.4.7 | Keyboard focus is visible |
| **AA** | 3.1.2 | Language of parts is identified |
| **AAA** | 1.4.6 | Contrast ratio at least 7:1 (normal text) |
| **AAA** | 1.4.8 | Visual presentation is configurable |
| **AAA** | 2.4.9 | Link purpose is clear from link text alone |
| **AAA** | 2.4.10 | Section headings organise content |

## Related

- `tools/browser/pagespeed.md` — Performance testing (includes Lighthouse accessibility score)
- `tools/performance/performance.md` — Core Web Vitals
- `tools/browser/browser-automation.md` — Browser tool selection for dynamic/SPA testing
- `seo/` — SEO (overlapping concerns: headings, alt text, semantic HTML)
- Chrome DevTools MCP — real-time accessibility tree inspection
