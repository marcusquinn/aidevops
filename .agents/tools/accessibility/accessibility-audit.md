---
description: Unified web and email accessibility auditing — WCAG compliance, remediation, and monitoring
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

# Accessibility Audit Service

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Unified accessibility auditing for websites and HTML emails
- **Helper**: `accessibility-helper.sh [audit|lighthouse|pa11y|wave|email|contrast|bulk]`
- **Standards**: WCAG 2.1 Level A, AA (default), AAA; WCAG 2.2 where tooling supports
- **Reports**: `~/.aidevops/reports/accessibility/`
- **Related**: `tools/accessibility/accessibility.md` (tool reference + WCAG quick reference), `services/email/email-testing.md`

```bash
accessibility-helper.sh audit https://example.com          # Full web audit (Lighthouse + pa11y + WAVE)
accessibility-helper.sh wave https://example.com           # WAVE API (CSS/JS-rendered analysis)
accessibility-helper.sh wave https://example.com 3         # WAVE with XPath element locations
accessibility-helper.sh email ./newsletter.html            # Email HTML accessibility check
accessibility-helper.sh contrast '#333333' '#ffffff'       # Contrast ratio check
accessibility-helper.sh bulk sites.txt                     # Bulk audit from URL list
```

<!-- AI-CONTEXT-END -->

## Tool Selection

| Scenario | Command |
|----------|---------|
| Quick score | `accessibility-helper.sh lighthouse <url>` |
| WCAG compliance | `accessibility-helper.sh pa11y <url> WCAG2AA` |
| CSS/JS-rendered analysis | `accessibility-helper.sh wave <url>` |
| Element-level issues | `accessibility-helper.sh wave <url> 3` |
| Mobile | `accessibility-helper.sh wave-mobile <url>` |
| Full audit (all engines) | `accessibility-helper.sh audit <url>` |
| Email template | `accessibility-helper.sh email <file>` |
| Contrast pair | `accessibility-helper.sh contrast <fg> <bg>` |
| Multi-site batch | `accessibility-helper.sh bulk <urls-file>` |
| Dynamic SPA content | Use `playwright` for JS-rendered pages |
| WAVE item docs | `accessibility-helper.sh wave-docs <item-id>` |

## Audit Workflow

### 1. Scope Definition

- **Pages**: Homepage, key landing pages, forms, checkout, login
- **Emails**: Transactional templates, marketing campaigns, automated sequences
- **Standards**: WCAG 2.1 AA (default) or AAA for public sector / high-compliance
- **Devices**: Desktop + mobile (both tested by default)

### 2. Results Interpretation

#### Web Audit Results

| Source | Output | Priority |
|--------|--------|----------|
| Lighthouse score | 0-100% accessibility rating | Overall health indicator |
| Lighthouse failures | Specific axe-core rule violations | Fix all binary failures |
| pa11y errors | WCAG criterion violations | Must fix (blocks compliance) |
| pa11y warnings | Likely issues needing review | Should fix |
| pa11y notices | Advisory best practices | Consider fixing |

#### Email Audit Results

| Check | WCAG Criterion | Severity |
|-------|---------------|----------|
| Missing `alt` on images | 1.1.1 Non-text Content | Error |
| Missing `lang` attribute | 3.1.1 Language of Page | Error |
| Layout tables without `role="presentation"` | 1.3.1 Info and Relationships | Warning |
| Font size below 14px | 1.4.4 Resize Text | Warning |
| Generic link text ("click here") | 2.4.4 Link Purpose | Warning |
| No heading structure | 1.3.1 Info and Relationships | Warning |
| Colour-only indicators | 1.4.1 Use of Colour | Warning |

### 3. Remediation Priority

**Fix first** (high impact, low effort): missing `alt` attributes, missing `lang`, colour contrast failures, missing `role="presentation"` on email layout tables, generic link text.

**Fix next** (high impact, higher effort): skip navigation, keyboard navigability, ARIA labels on interactive components, heading hierarchy, form label associations.

**Then** (medium impact): focus indicators, 44x44px touch targets, `prefers-reduced-motion`, text alternatives for video/audio.

For WCAG checklist details and criterion reference, see `tools/accessibility/accessibility.md`.

## Monitoring and CI/CD

### Scheduled Audits

```bash
cron-helper.sh add "accessibility-audit" \
  "0 6 * * 1" \
  "accessibility-helper.sh bulk ~/.aidevops/reports/accessibility/monitored-urls.txt"

# Track scores over time
jq -r '.categories.accessibility.score * 100' \
  ~/.aidevops/reports/accessibility/lighthouse_a11y_*.json
```

### CI/CD Integration

```bash
# Fail build if Lighthouse accessibility score drops below 90
score=$(accessibility-helper.sh lighthouse https://staging.example.com \
  | sed $'s/\033\\[[0-9;]*m//g' | sed -E -n 's/.*Score: ([0-9]+).*/\1/p')
[[ -z "$score" ]] && echo "Error: Could not parse accessibility score" >&2 && exit 1
[[ "$score" -lt 90 ]] && echo "Accessibility score $score% is below 90% threshold" && exit 1

# Fail build if pa11y finds errors
accessibility-helper.sh pa11y https://staging.example.com WCAG2AA
```

## Related

- `tools/accessibility/accessibility.md` — Tool reference, WCAG quick reference, email-specific rules
- `services/email/email-testing.md` — Email design rendering and delivery testing
- `services/email/email-health-check.md` — Email DNS authentication checks
- `tools/browser/pagespeed.md` — Performance testing (includes accessibility score)
- `tools/browser/playwright.md` — Browser automation for dynamic content testing
- `seo/` — SEO optimization (overlapping accessibility concerns)
