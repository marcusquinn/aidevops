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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Accessibility & Contrast Testing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `accessibility-helper.sh` — Lighthouse, pa11y, Playwright contrast, WAVE API, email, contrast calc
- **Audit Helper**: `accessibility-audit-helper.sh` — axe-core, WAVE API, WebAIM contrast, Lighthouse
- **Commands (helper)**: `audit` | `lighthouse` | `pa11y` | `playwright-contrast` | `wave` | `email` | `contrast` | `bulk`
- **Commands (audit)**: `axe` | `wave` | `contrast` | `compare` | `status`
- **Install**: either helper's `install-deps` command
- **Standards**: WCAG 2.1 A, AA (default), AAA
- **Reports**: `~/.aidevops/reports/accessibility/` and `~/.aidevops/reports/accessibility-audit/`
- **Env**: `A11Y_WCAG_LEVEL` / `AUDIT_WCAG_LEVEL` (default `WCAG2AA`), `WAVE_API_KEY`

<!-- AI-CONTEXT-END -->

## Tools Overview

| Tool | Helper | Purpose | Speed |
|------|--------|---------|-------|
| **Lighthouse** | both | Score + audit failures (axe-core engine) | ~15s |
| **pa11y** | helper | WCAG violations (HTML_CodeSniffer) | ~10s |
| **Playwright contrast** | helper | Computed style analysis, all visible elements | ~5-15s |
| **WAVE API** | both | Full analysis incl. CSS/JS-rendered content | ~2-5s |
| **@axe-core/cli** | audit | Standalone axe scanner | ~10s |
| **WebAIM Contrast API** | audit | Colour contrast check (no key required) | Instant |
| **Email checker** | helper | HTML email a11y (static analysis) | <1s |
| **Contrast calculator** | helper | WCAG contrast ratio for color pairs | Instant |

## Setup

```bash
accessibility-helper.sh install-deps
accessibility-audit-helper.sh install-deps

# WAVE API key (optional — https://wave.webaim.org/api/register)
aidevops secret set wave-api-key   # encrypted (recommended)
export WAVE_API_KEY="your-key"     # or env var
```

## Usage

### accessibility-helper.sh

```bash
# Full audit (Lighthouse + pa11y, desktop and mobile)
accessibility-helper.sh audit https://example.com

# Lighthouse — score, failed audits, ARIA validation
accessibility-helper.sh lighthouse https://example.com         # desktop
accessibility-helper.sh lighthouse https://example.com mobile  # mobile

# pa11y — errors/warnings/notices by WCAG level
accessibility-helper.sh pa11y https://example.com           # AA (default)
accessibility-helper.sh pa11y https://example.com WCAG2AAA  # AAA
accessibility-helper.sh pa11y https://example.com WCAG2A    # A

# WAVE API (requires WAVE_API_KEY) — CSS/JS-rendered analysis
# Types: 1=counts, 2=+details (default), 3=+XPath, 4=+CSS selectors
accessibility-helper.sh wave https://example.com    # type 2
accessibility-helper.sh wave https://example.com 3  # + XPath locations
accessibility-helper.sh wave https://example.com 4  # + CSS selectors
accessibility-helper.sh wave-mobile https://example.com  # 375px viewport
accessibility-helper.sh wave-docs alt_missing            # look up WAVE item
accessibility-helper.sh wave-credits                     # check remaining credits

# Contrast ratio — AA normal (4.5:1), AA large (3:1), AAA normal (7:1), AAA large (4.5:1)
accessibility-helper.sh contrast '#333333' '#ffffff'

# Playwright contrast — SC 1.4.3/1.4.6, computed fg/bg, large text (≥18pt/14pt bold), gradient flags. Exit: 0=pass, 1=fail, 2=error.
accessibility-helper.sh playwright-contrast https://example.com           # summary
accessibility-helper.sh playwright-contrast https://example.com json      # JSON
accessibility-helper.sh playwright-contrast https://example.com markdown AAA
node .agents/scripts/accessibility/playwright-contrast.mjs https://example.com --format json --fail-only  # fail-only flag
node .agents/scripts/accessibility/playwright-contrast.mjs https://example.com --limit 20                 # limit results

# Email HTML — alt (1.1.1), lang (3.1.1), role="presentation" (1.3.1), font <12px (1.4.4), link text (2.4.4), headings (1.3.1), color-only (1.4.1)
accessibility-helper.sh email ./newsletter.html

# Bulk audit — one URL per line, # for comments
accessibility-helper.sh bulk sites.txt
```

### accessibility-audit-helper.sh

```bash
accessibility-audit-helper.sh axe https://example.com                    # default: wcag2a, wcag2aa, best-practice
accessibility-audit-helper.sh axe https://example.com wcag2aa,wcag21aa
accessibility-audit-helper.sh wave https://example.com                   # requires WAVE_API_KEY
accessibility-audit-helper.sh contrast '#333333' '#ffffff'               # WebAIM, no key
accessibility-audit-helper.sh compare https://example.com               # multi-engine comparison
accessibility-audit-helper.sh status                                     # check installed engines
```

## WCAG 2.1 Quick Reference

| Level | Key Criteria |
|-------|-------------|
| **A** | 1.1.1 text alternatives · 1.3.1 programmatic structure · 1.4.1 not color-only · 2.1.1 keyboard accessible · 2.4.1 skip nav · 4.1.1 valid HTML · 4.1.2 name/role/value |
| **AA** | 1.4.3 contrast ≥4.5:1 · 1.4.4 resize to 200% · 1.4.5 real text not images · 2.4.6 descriptive headings/labels · 2.4.7 visible focus · 3.1.2 language of parts |
| **AAA** | 1.4.6 contrast ≥7:1 · 1.4.8 configurable presentation · 2.4.9 link purpose from text · 2.4.10 section headings |

## Related

- `tools/browser/pagespeed.md` — Lighthouse a11y score
- `tools/performance/performance.md` — Core Web Vitals
- `tools/browser/browser-automation.md` — dynamic/SPA testing
- `seo/` — overlapping: headings, alt text, semantic HTML
- Chrome DevTools MCP — accessibility tree inspection
