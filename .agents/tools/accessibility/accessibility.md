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

- **Helper**: `.agents/scripts/accessibility-helper.sh`
- **Commands**: `audit [url]` | `lighthouse [url]` | `pa11y [url]` | `wave [url]` | `email [file]` | `contrast [fg] [bg]` | `bulk [file]`
- **Install**: `npm install -g lighthouse pa11y` or `.agents/scripts/accessibility-helper.sh install-deps`
- **Standards**: WCAG 2.1 Level A, AA (default), AAA
- **Reports**: `~/.aidevops/reports/accessibility/`
- **Tools**: Lighthouse (accessibility category), pa11y (WCAG runner), WAVE API (comprehensive analysis), built-in contrast calculator, email HTML checker

<!-- AI-CONTEXT-END -->

## Overview

Comprehensive WCAG compliance testing for websites and HTML emails. Combines multiple tools into a single workflow:

| Tool | Purpose | Speed | Depth |
|------|---------|-------|-------|
| **Lighthouse** | Accessibility score + audit failures | ~15s | Broad (axe-core engine) |
| **pa11y** | WCAG-specific violation reporting | ~10s | Deep (HTML_CodeSniffer) |
| **WAVE API** | Comprehensive accessibility analysis | ~2-5s | Deep (WAVE engine, CSS/JS-rendered) |
| **Email checker** | HTML email accessibility (static analysis) | <1s | Email-specific rules |
| **Contrast calculator** | WCAG contrast ratio for color pairs | Instant | AA + AAA levels |

## Setup

```bash
# Install all dependencies
.agents/scripts/accessibility-helper.sh install-deps

# Or install individually
npm install -g lighthouse   # Required
npm install -g pa11y        # Recommended (WCAG-specific testing)
brew install jq             # Required (JSON parsing)
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

## Integration with Other Tools

| Tool | Integration |
|------|-------------|
| **WAVE API** | Comprehensive analysis with CSS/JS rendering, contrast data, XPath/CSS selectors |
| **PageSpeed** | `pagespeed-helper.sh` includes Lighthouse accessibility score |
| **Playwright** | Use for dynamic content testing (SPA accessibility) |
| **Chrome DevTools MCP** | Real-time accessibility tree inspection |
| **SEO** | Accessibility overlaps with SEO (headings, alt text, semantic HTML) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `A11Y_WCAG_LEVEL` | `WCAG2AA` | Default WCAG standard for pa11y |
| `WAVE_API_KEY` | — | WAVE API key (or use `aidevops secret set wave-api-key`) |

## Report Storage

All reports are saved to `~/.aidevops/reports/accessibility/`:

- `lighthouse_a11y_YYYYMMDD_HHMMSS.json` — Lighthouse accessibility audit
- `pa11y_YYYYMMDD_HHMMSS.json` — pa11y WCAG violations
- `wave_YYYYMMDD_HHMMSS.json` — WAVE API analysis results
- `email_a11y_YYYYMMDD_HHMMSS.txt` — Email HTML check results

## Related

- `tools/browser/pagespeed.md` — Performance testing (includes accessibility score)
- `tools/performance/performance.md` — Core Web Vitals
- `seo/` — SEO optimization (overlapping concerns)
- `tools/browser/browser-automation.md` — Browser tool selection for dynamic testing
