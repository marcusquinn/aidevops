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

### accessibility-helper.sh

```bash
# Full audit — Lighthouse + pa11y, desktop and mobile
.agents/scripts/accessibility-helper.sh audit https://example.com

# Lighthouse — score (0-100%), failed audits (contrast, ARIA, labels), ARIA validation
.agents/scripts/accessibility-helper.sh lighthouse https://example.com         # desktop
.agents/scripts/accessibility-helper.sh lighthouse https://example.com mobile  # mobile

# pa11y — errors (must fix), warnings (should fix), notices (advisory)
.agents/scripts/accessibility-helper.sh pa11y https://example.com           # AA (default)
.agents/scripts/accessibility-helper.sh pa11y https://example.com WCAG2AAA  # AAA
.agents/scripts/accessibility-helper.sh pa11y https://example.com WCAG2A    # A

# WAVE API (requires WAVE_API_KEY) — evaluates after CSS/JS rendering
# Types: 1=counts (1 credit), 2=+details (2 credits), 3/4=+locations+contrast (3 credits)
# Categories: errors, contrast errors, alerts, features, structural elements, ARIA
.agents/scripts/accessibility-helper.sh wave https://example.com    # type 2 (default)
.agents/scripts/accessibility-helper.sh wave https://example.com 3  # + XPath locations
.agents/scripts/accessibility-helper.sh wave https://example.com 4  # + CSS selectors
.agents/scripts/accessibility-helper.sh wave-mobile https://example.com  # 375px viewport
.agents/scripts/accessibility-helper.sh wave-docs alt_missing            # look up WAVE item
.agents/scripts/accessibility-helper.sh wave-credits                     # check remaining credits

# Contrast ratio — pass/fail for AA normal (4.5:1), AA large (3:1), AAA normal (7:1), AAA large (4.5:1)
.agents/scripts/accessibility-helper.sh contrast '#333333' '#ffffff'

# Playwright contrast — headless DOM traversal; computed fg/bg colors, font size/weight,
# WCAG ratio per element (L1+0.05)/(L2+0.05), SC 1.4.3/1.4.6, large text (≥18pt or ≥14pt bold),
# gradient/image background flags. Exit: 0=pass, 1=failures, 2=script error.
.agents/scripts/accessibility-helper.sh playwright-contrast https://example.com           # summary
.agents/scripts/accessibility-helper.sh playwright-contrast https://example.com json      # JSON
.agents/scripts/accessibility-helper.sh playwright-contrast https://example.com markdown AAA
node .agents/scripts/accessibility/playwright-contrast.mjs https://example.com --format json --fail-only
node .agents/scripts/accessibility/playwright-contrast.mjs https://example.com --limit 20

# Email HTML — checks: alt (1.1.1), lang (3.1.1), role="presentation" on layout tables (1.3.1),
# font <12px (1.4.4), generic link text (2.4.4), heading structure (1.3.1), color-only (1.4.1)
# Key: email clients strip CSS/JS — use alt text, role="presentation", lang, ≥14px font, descriptive links
.agents/scripts/accessibility-helper.sh email ./newsletter.html

# Bulk audit — one URL per line, # for comments
.agents/scripts/accessibility-helper.sh bulk sites.txt
```

### accessibility-audit-helper.sh

```bash
.agents/scripts/accessibility-audit-helper.sh axe https://example.com                    # default: wcag2a, wcag2aa, best-practice
.agents/scripts/accessibility-audit-helper.sh axe https://example.com wcag2aa,wcag21aa
.agents/scripts/accessibility-audit-helper.sh wave https://example.com                   # requires WAVE_API_KEY
.agents/scripts/accessibility-audit-helper.sh contrast '#333333' '#ffffff'               # WebAIM, no key required
.agents/scripts/accessibility-audit-helper.sh compare https://example.com               # multi-engine comparison
.agents/scripts/accessibility-audit-helper.sh status                                     # check installed engines
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
