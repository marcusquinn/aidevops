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

- **Helper**: `.agents/scripts/accessibility-helper.sh` (Lighthouse, pa11y, Playwright contrast, WAVE API, email, contrast calc)
- **Audit Helper**: `.agents/scripts/accessibility-audit-helper.sh` (axe-core, WAVE API, WebAIM contrast, Lighthouse)
- **Commands**: `audit [url]` | `lighthouse [url]` | `pa11y [url]` | `playwright-contrast [url]` | `wave [url]` | `email [file]` | `contrast [fg] [bg]` | `bulk [file]`
- **Audit Commands**: `audit [url]` | `axe [url]` | `wave [url]` | `contrast [fg] [bg]` | `compare [url]` | `status`
- **Install**: `npm install -g lighthouse pa11y @axe-core/cli` and `npm install playwright && npx playwright install chromium` or `accessibility-audit-helper.sh install-deps`
- **Standards**: WCAG 2.1 Level A, AA (default), AAA
- **Reports**: `~/.aidevops/reports/accessibility/` and `~/.aidevops/reports/accessibility-audit/`
- **Tools**: Lighthouse (accessibility category), pa11y (WCAG runner), Playwright contrast extraction, WAVE API (comprehensive analysis), axe-core (standalone axe scanner), WebAIM contrast API, built-in contrast calculator, email HTML checker

<!-- AI-CONTEXT-END -->

## Overview

Comprehensive WCAG compliance testing for websites and HTML emails. Two helper scripts provide complementary coverage:

### accessibility-helper.sh (original)

| Tool | Purpose | Speed | Depth |
|------|---------|-------|-------|
| **Lighthouse** | Accessibility score + audit failures | ~15s | Broad (axe-core engine) |
| **pa11y** | WCAG-specific violation reporting | ~10s | Deep (HTML_CodeSniffer) |
| **Playwright contrast** | Computed style analysis for all visible elements | ~5-15s | Every text element on page |
| **WAVE API** | Comprehensive accessibility analysis | ~2-5s | Deep (WAVE engine, CSS/JS-rendered) |
| **Email checker** | HTML email accessibility (static analysis) | <1s | Email-specific rules |
| **Contrast calculator** | WCAG contrast ratio for color pairs | Instant | AA + AAA levels |

### accessibility-audit-helper.sh (extended)

| Tool | Purpose | Speed | Depth |
|------|---------|-------|-------|
| **@axe-core/cli** | Standalone axe accessibility scanner | ~10s | Deep (axe-core direct) |
| **WAVE API** | WebAIM visual accessibility evaluator | ~5s | Broad (errors, alerts, contrast, ARIA) |
| **WebAIM Contrast API** | Programmatic colour contrast checks | Instant | AA + AAA levels |
| **Lighthouse** | Accessibility score + audit failures | ~15s | Broad (axe-core engine) |

## Setup

```bash
# Install all dependencies (original helper)
.agents/scripts/accessibility-helper.sh install-deps

# Install all dependencies (audit helper)
.agents/scripts/accessibility-audit-helper.sh install-deps

# Or install individually
npm install -g lighthouse       # Required
npm install -g pa11y            # Recommended (WCAG-specific testing)
npm install -g @axe-core/cli    # Required for axe command
brew install jq                 # Required (JSON parsing)

# WAVE API key (optional, for wave command)
export WAVE_API_KEY=<your-key>  # Get at https://wave.webaim.org/api/
```

## Usage

### Full Audit (Recommended)

Runs Lighthouse accessibility + pa11y WCAG testing on both desktop and mobile:

```bash
.agents/scripts/accessibility-helper.sh audit https://example.com
```

### Lighthouse Accessibility Only

Focused accessibility audit using Lighthouse's axe-core engine:

```bash
# Desktop (default)
.agents/scripts/accessibility-helper.sh lighthouse https://example.com

# Mobile
.agents/scripts/accessibility-helper.sh lighthouse https://example.com mobile
```

Reports include:
- Accessibility score (0-100%)
- Failed audits (contrast, ARIA, labels, etc.)
- Contrast-specific issues
- ARIA validation

### pa11y WCAG Testing

Standards-based testing with HTML_CodeSniffer:

```bash
# Default: WCAG 2.1 AA
.agents/scripts/accessibility-helper.sh pa11y https://example.com

# Strict: WCAG 2.1 AAA
.agents/scripts/accessibility-helper.sh pa11y https://example.com WCAG2AAA

# Basic: WCAG 2.1 A
.agents/scripts/accessibility-helper.sh pa11y https://example.com WCAG2A
```

Reports categorise issues as errors (must fix), warnings (should fix), and notices (advisory).

### WAVE API Analysis

Comprehensive accessibility analysis using the WAVE engine. Evaluates pages after CSS and JavaScript rendering for accurate results. Requires an API key (register at https://wave.webaim.org/api/register).

```bash
# Basic WAVE audit (report type 2 — item details, 2 credits)
.agents/scripts/accessibility-helper.sh wave https://example.com

# Detailed with XPath locations (report type 3, 3 credits)
.agents/scripts/accessibility-helper.sh wave https://example.com 3

# Detailed with CSS selectors (report type 4, 3 credits)
.agents/scripts/accessibility-helper.sh wave https://example.com 4

# Mobile viewport (375px)
.agents/scripts/accessibility-helper.sh wave-mobile https://example.com

# Look up a specific WAVE item
.agents/scripts/accessibility-helper.sh wave-docs alt_missing

# Check remaining API credits
.agents/scripts/accessibility-helper.sh wave-credits
```

**Report types:**

| Type | Cost | Data |
|------|------|------|
| 1 | 1 credit | Category counts only (errors, alerts, features, etc.) |
| 2 | 2 credits | Category counts + item details (default) |
| 3 | 3 credits | All above + XPath locations + contrast data |
| 4 | 3 credits | All above + CSS selector locations + contrast data |

**API key setup:**

```bash
# Encrypted (recommended)
aidevops secret set wave-api-key

# Or environment variable
export WAVE_API_KEY="your-key-here"
```

WAVE categories: errors (must fix), contrast errors, alerts (should review), features (positive), structural elements, ARIA usage.

### Email HTML Accessibility

Static analysis of HTML email files for common accessibility issues:

```bash
.agents/scripts/accessibility-helper.sh email ./newsletter.html
```

Checks:
- Images without `alt` attributes (WCAG 1.1.1)
- Missing `lang` attribute on `<html>` (WCAG 3.1.1)
- Layout tables without `role="presentation"` (WCAG 1.3.1)
- Small font sizes below 12px (WCAG 1.4.4)
- Generic link text like "click here" (WCAG 2.4.4)
- Heading structure (WCAG 1.3.1)
- Color-only information indicators (WCAG 1.4.1)

### Contrast Ratio Calculator

Check any foreground/background color pair against WCAG requirements:

```bash
.agents/scripts/accessibility-helper.sh contrast '#333333' '#ffffff'
```

Output includes pass/fail for:
- **WCAG AA** normal text (4.5:1 minimum)
- **WCAG AA** large text (3:1 minimum)
- **WCAG AAA** normal text (7:1 minimum)
- **WCAG AAA** large text (4.5:1 minimum)

### Playwright Contrast Extraction

Automated computed-style analysis of every visible text element on a page. Uses Playwright to render the page headlessly, then traverses the DOM extracting actual foreground/background colors (resolving transparent backgrounds by walking ancestors), font sizes, and weights. Calculates WCAG contrast ratios and reports pass/fail per element.

```bash
# Summary report (default)
.agents/scripts/accessibility-helper.sh playwright-contrast https://example.com

# JSON output for programmatic use
.agents/scripts/accessibility-helper.sh playwright-contrast https://example.com json

# Markdown report at AAA level
.agents/scripts/accessibility-helper.sh playwright-contrast https://example.com markdown AAA
```

Or use the Node.js script directly for more options:

```bash
# Fail-only JSON output
node .agents/scripts/accessibility/playwright-contrast.mjs https://example.com --format json --fail-only

# Limit to first 20 elements
node .agents/scripts/accessibility/playwright-contrast.mjs https://example.com --limit 20
```

Per-element output includes:

- **Element selector** — CSS path to the element
- **Foreground/background colors** — computed RGB values (after resolving transparency and opacity)
- **Contrast ratio** — calculated per WCAG formula `(L1 + 0.05) / (L2 + 0.05)`
- **Pass/fail** — against AA (4.5:1 normal, 3:1 large) and AAA (7:1 normal, 4.5:1 large)
- **WCAG criterion** — SC 1.4.3 (AA) or SC 1.4.6 (AAA), with large text variant
- **Large text detection** — >= 18pt or >= 14pt bold
- **Complex background flags** — gradients and background images flagged for manual review

Exit codes: 0 = all pass, 1 = contrast failures found, 2 = script error.

### Bulk Audit

Audit multiple websites from a file:

```bash
# Create URLs file (one per line, # for comments)
cat > sites.txt << EOF
https://example.com
https://mysite.com
# https://skip-this.com
EOF

.agents/scripts/accessibility-helper.sh bulk sites.txt
```

## WCAG 2.1 Quick Reference

### Level A (Minimum)

| Criterion | Description |
|-----------|-------------|
| 1.1.1 | Non-text content has text alternatives |
| 1.3.1 | Information and relationships are programmatically determinable |
| 1.4.1 | Color is not the only means of conveying information |
| 2.1.1 | All functionality is keyboard accessible |
| 2.4.1 | Skip navigation mechanism available |
| 4.1.1 | HTML validates without significant errors |
| 4.1.2 | Name, role, value for all UI components |

### Level AA (Standard Target)

| Criterion | Description |
|-----------|-------------|
| 1.4.3 | Contrast ratio at least 4.5:1 (normal text) |
| 1.4.4 | Text can be resized up to 200% without loss |
| 1.4.5 | Text is used instead of images of text |
| 2.4.6 | Headings and labels describe topic or purpose |
| 2.4.7 | Keyboard focus is visible |
| 3.1.2 | Language of parts is identified |

### Level AAA (Enhanced)

| Criterion | Description |
|-----------|-------------|
| 1.4.6 | Contrast ratio at least 7:1 (normal text) |
| 1.4.8 | Visual presentation is configurable |
| 2.4.9 | Link purpose is clear from link text alone |
| 2.4.10 | Section headings organise content |

## Email-Specific Accessibility

HTML emails have unique constraints because email clients strip most CSS and JavaScript. Key rules:

1. **Always include `alt` text on images** — many clients block images by default
2. **Use `role="presentation"` on layout tables** — screen readers interpret tables as data
3. **Set `lang` attribute** — screen readers need language context
4. **Minimum 14px font size** — email clients render inconsistently at smaller sizes
5. **Avoid colour-only indicators** — use text labels alongside colour cues
6. **Descriptive link text** — "View your order" not "Click here"
7. **Logical reading order** — table-based layouts must read correctly when linearised
8. **Preheader text** — provide meaningful preview text for screen readers

## Audit Helper Usage

### axe-core Standalone Audit

```bash
# Default tags: wcag2a, wcag2aa, best-practice
.agents/scripts/accessibility-audit-helper.sh axe https://example.com

# Custom tags
.agents/scripts/accessibility-audit-helper.sh axe https://example.com wcag2aa,wcag21aa
```

### WAVE API Audit

Requires `WAVE_API_KEY` environment variable:

```bash
.agents/scripts/accessibility-audit-helper.sh wave https://example.com
```

### WebAIM Contrast Checker API

Programmatic contrast check via WebAIM's API (no key required):

```bash
.agents/scripts/accessibility-audit-helper.sh contrast '#333333' '#ffffff'
```

### Multi-Engine Comparison

Run all available engines against a single URL and compare results:

```bash
.agents/scripts/accessibility-audit-helper.sh compare https://example.com
```

### Tool Status

Check which engines are installed and configured:

```bash
.agents/scripts/accessibility-audit-helper.sh status
```

## Integration with Other Tools

| Tool | Integration |
|------|-------------|
| **WAVE API** | Comprehensive analysis with CSS/JS rendering, contrast data, XPath/CSS selectors |
| **PageSpeed** | `pagespeed-helper.sh` includes Lighthouse accessibility score |
| **Playwright** | Contrast extraction for all visible elements (`playwright-contrast` command) + dynamic SPA testing |
| **Chrome DevTools MCP** | Real-time accessibility tree inspection |
| **SEO** | Accessibility overlaps with SEO (headings, alt text, semantic HTML) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `A11Y_WCAG_LEVEL` | `WCAG2AA` | Default WCAG standard for pa11y |
| `AUDIT_WCAG_LEVEL` | `WCAG2AA` | Default WCAG level for audit helper |
| `WAVE_API_KEY` | — | WAVE API key (or use `aidevops secret set wave-api-key`) |

## Report Storage

Reports from `accessibility-helper.sh` are saved to `~/.aidevops/reports/accessibility/`:

- `lighthouse_a11y_YYYYMMDD_HHMMSS.json` — Lighthouse accessibility audit
- `pa11y_YYYYMMDD_HHMMSS.json` — pa11y WCAG violations
- `playwright_contrast_YYYYMMDD_HHMMSS.{json,md,txt}` — Playwright contrast extraction
- `wave_YYYYMMDD_HHMMSS.json` — WAVE API analysis results
- `email_a11y_YYYYMMDD_HHMMSS.txt` — Email HTML check results

Reports from `accessibility-audit-helper.sh` are saved to `~/.aidevops/reports/accessibility-audit/`:

- `axe_YYYYMMDD_HHMMSS.json` — axe-core standalone audit
- `wave_YYYYMMDD_HHMMSS.json` — WAVE API report
- `webaim_contrast_YYYYMMDD_HHMMSS.json` — WebAIM contrast check
- `lighthouse_a11y_YYYYMMDD_HHMMSS.json` — Lighthouse accessibility audit
- `comparison_YYYYMMDD_HHMMSS.txt` — Multi-engine comparison

## Related

- `tools/browser/pagespeed.md` — Performance testing (includes accessibility score)
- `tools/performance/performance.md` — Core Web Vitals
- `seo/` — SEO optimization (overlapping concerns)
- `tools/browser/browser-automation.md` — Browser tool selection for dynamic testing
