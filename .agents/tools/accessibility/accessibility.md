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
- **Standards**: WCAG 2.1 Level A, AA (default), AAA
- **Reports**: `~/.aidevops/reports/accessibility/` and `~/.aidevops/reports/accessibility-audit/`

<!-- AI-CONTEXT-END -->

## Setup

```bash
# Install all dependencies
.agents/scripts/accessibility-helper.sh install-deps
.agents/scripts/accessibility-audit-helper.sh install-deps

# Or individually
npm install -g lighthouse pa11y @axe-core/cli
brew install jq

# WAVE API key (optional)
aidevops secret set wave-api-key   # or: export WAVE_API_KEY=<key>
# Register at https://wave.webaim.org/api/register
```

## accessibility-helper.sh

| Command | Tool | Purpose | Speed |
|---------|------|---------|-------|
| `audit [url]` | Lighthouse + pa11y | Full audit (desktop + mobile) | ~25s |
| `lighthouse [url] [mobile]` | Lighthouse/axe-core | Score + failed audits | ~15s |
| `pa11y [url] [WCAG2AA]` | HTML_CodeSniffer | WCAG violations | ~10s |
| `wave [url] [type]` | WAVE API | Comprehensive analysis | ~5s |
| `wave-mobile [url]` | WAVE API | Mobile viewport (375px) | ~5s |
| `playwright-contrast [url] [fmt] [lvl]` | Playwright | Computed contrast for all elements | ~15s |
| `email [file]` | Static | HTML email accessibility | <1s |
| `contrast [fg] [bg]` | Built-in | WCAG contrast ratio | Instant |
| `bulk [file]` | All | Audit multiple URLs from file | varies |

```bash
# Examples
.agents/scripts/accessibility-helper.sh audit https://example.com
.agents/scripts/accessibility-helper.sh pa11y https://example.com WCAG2AAA
.agents/scripts/accessibility-helper.sh wave https://example.com 3   # XPath locations, 3 credits
.agents/scripts/accessibility-helper.sh playwright-contrast https://example.com json
.agents/scripts/accessibility-helper.sh contrast '#333333' '#ffffff'
.agents/scripts/accessibility-helper.sh email ./newsletter.html

# Playwright: direct script for more options
node .agents/scripts/accessibility/playwright-contrast.mjs https://example.com --format json --fail-only --limit 20
```

**WAVE report types:** 1 = counts only (1 credit), 2 = item details (2 credits, default), 3 = XPath + contrast (3 credits), 4 = CSS selectors + contrast (3 credits).

**Playwright exit codes:** 0 = all pass, 1 = contrast failures, 2 = script error.

## accessibility-audit-helper.sh

| Command | Tool | Purpose |
|---------|------|---------|
| `audit [url]` | All engines | Full audit |
| `axe [url] [tags]` | @axe-core/cli | Standalone axe scan (default: wcag2a,wcag2aa,best-practice) |
| `wave [url]` | WAVE API | Requires `WAVE_API_KEY` |
| `contrast [fg] [bg]` | WebAIM API | Programmatic contrast (no key required) |
| `compare [url]` | All engines | Multi-engine comparison |
| `status` | — | Check installed engines |

```bash
.agents/scripts/accessibility-audit-helper.sh axe https://example.com wcag2aa,wcag21aa
.agents/scripts/accessibility-audit-helper.sh compare https://example.com
.agents/scripts/accessibility-audit-helper.sh status
```

## WCAG 2.1 Quick Reference

| Level | Criterion | Rule |
|-------|-----------|------|
| A | 1.1.1 | Non-text content has text alternatives |
| A | 1.3.1 | Information/relationships programmatically determinable |
| A | 1.4.1 | Color not the only means of conveying information |
| A | 2.1.1 | All functionality keyboard accessible |
| A | 4.1.2 | Name, role, value for all UI components |
| AA | 1.4.3 | Contrast ≥ 4.5:1 normal text, 3:1 large text |
| AA | 1.4.4 | Text resizable to 200% without loss |
| AA | 2.4.7 | Keyboard focus visible |
| AAA | 1.4.6 | Contrast ≥ 7:1 normal text, 4.5:1 large text |
| AAA | 2.4.9 | Link purpose clear from link text alone |

## Email Accessibility

Email clients strip CSS/JS. Key rules:

1. `alt` text on all images — clients block images by default (WCAG 1.1.1)
2. `role="presentation"` on layout tables — screen readers treat tables as data (WCAG 1.3.1)
3. `lang` attribute on `<html>` — screen readers need language context (WCAG 3.1.1)
4. Minimum 14px font — clients render inconsistently below this
5. No colour-only indicators — use text labels alongside colour cues (WCAG 1.4.1)
6. Descriptive link text — "View your order" not "Click here" (WCAG 2.4.4)
7. Logical reading order — table layouts must linearise correctly

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `A11Y_WCAG_LEVEL` | `WCAG2AA` | Default WCAG level for pa11y |
| `AUDIT_WCAG_LEVEL` | `WCAG2AA` | Default WCAG level for audit helper |
| `WAVE_API_KEY` | — | WAVE API key |

## Report Files

`~/.aidevops/reports/accessibility/`: `lighthouse_a11y_*.json`, `pa11y_*.json`, `playwright_contrast_*.{json,md,txt}`, `wave_*.json`, `email_a11y_*.txt`

`~/.aidevops/reports/accessibility-audit/`: `axe_*.json`, `wave_*.json`, `webaim_contrast_*.json`, `lighthouse_a11y_*.json`, `comparison_*.txt`

## Related

- `tools/browser/pagespeed.md` — Performance testing (includes accessibility score)
- `tools/browser/browser-automation.md` — Browser tool selection for dynamic testing
- `seo/` — Overlapping concerns: headings, alt text, semantic HTML
