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
- **Helper**: `accessibility-helper.sh [audit|lighthouse|pa11y|email|contrast|bulk]`
- **Standards**: WCAG 2.1 Level A, AA (default), AAA; WCAG 2.2 where tooling supports
- **Reports**: `~/.aidevops/reports/accessibility/`
- **Related**: `tools/accessibility/accessibility.md` (tool reference), `services/email/email-testing.md` (email rendering)

**Quick commands:**

```bash
# Full web audit (Lighthouse + pa11y, desktop + mobile)
accessibility-helper.sh audit https://example.com

# Email HTML accessibility check
accessibility-helper.sh email ./newsletter.html

# Contrast ratio check
accessibility-helper.sh contrast '#333333' '#ffffff'

# Bulk audit from URL list
accessibility-helper.sh bulk sites.txt
```

<!-- AI-CONTEXT-END -->

## Overview

This agent orchestrates accessibility auditing across web and email channels. It combines automated tooling with manual review guidance to produce actionable remediation plans.

| Channel | Tools | Coverage |
|---------|-------|----------|
| **Web (desktop)** | Lighthouse, pa11y | axe-core engine + HTML_CodeSniffer |
| **Web (mobile)** | Lighthouse mobile, pa11y | Touch targets, viewport, zoom |
| **HTML email** | Built-in static analysis | Email-specific WCAG subset |
| **Colour** | Built-in contrast calculator | WCAG AA + AAA ratios |

## Audit Workflow

### 1. Scope Definition

Before running tools, define the audit scope:

- **Pages**: Homepage, key landing pages, forms, checkout, login
- **Emails**: Transactional templates, marketing campaigns, automated sequences
- **Standards**: WCAG 2.1 AA (default) or AAA for public sector / high-compliance
- **Devices**: Desktop + mobile (both tested by default)

### 2. Automated Scanning

Run the full audit to get baseline scores:

```bash
# Single URL — runs Lighthouse (desktop + mobile) and pa11y
accessibility-helper.sh audit https://example.com

# Multiple URLs from file
accessibility-helper.sh bulk sites.txt

# Email template
accessibility-helper.sh email ./templates/welcome.html
```

### 3. Results Interpretation

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
| Font size below 12px | 1.4.4 Resize Text | Warning |
| Generic link text ("click here") | 2.4.4 Link Purpose | Warning |
| No heading structure | 1.3.1 Info and Relationships | Warning |
| Colour-only indicators | 1.4.1 Use of Colour | Warning |

### 4. Remediation Planning

After scanning, prioritise fixes by impact and effort:

**High impact, low effort (fix first):**

- Add missing `alt` attributes to images
- Add `lang` attribute to `<html>` tag
- Fix colour contrast failures (update CSS colours)
- Add `role="presentation"` to layout tables in emails
- Replace generic link text with descriptive labels

**High impact, higher effort:**

- Add skip navigation links
- Ensure full keyboard navigability
- Add ARIA labels to interactive components
- Fix heading hierarchy (h1 > h2 > h3, no skips)
- Ensure form inputs have associated labels

**Medium impact:**

- Add focus indicators for keyboard users
- Ensure touch targets are at least 44x44px on mobile
- Add `prefers-reduced-motion` media queries
- Provide text alternatives for video/audio content

### 5. Verification

Re-run the audit after fixes to confirm resolution:

```bash
# Re-audit and compare scores
accessibility-helper.sh audit https://example.com

# Check specific contrast fix
accessibility-helper.sh contrast '#595959' '#ffffff'
```

## Web Accessibility Checklist

### Perceivable (WCAG Principle 1)

- [ ] All images have meaningful `alt` text (or `alt=""` for decorative)
- [ ] Video has captions; audio has transcripts
- [ ] Colour is not the sole means of conveying information
- [ ] Text contrast meets 4.5:1 (normal) or 3:1 (large) for AA
- [ ] Content is readable at 200% zoom without horizontal scrolling
- [ ] Text spacing can be adjusted without loss of content

### Operable (WCAG Principle 2)

- [ ] All functionality is keyboard accessible
- [ ] No keyboard traps exist
- [ ] Skip navigation link is present
- [ ] Page titles are descriptive and unique
- [ ] Focus order follows logical reading order
- [ ] Focus indicators are visible
- [ ] Touch targets are at least 44x44 CSS pixels

### Understandable (WCAG Principle 3)

- [ ] Page language is declared (`lang` attribute)
- [ ] Language changes within content are marked
- [ ] Form inputs have visible labels
- [ ] Error messages identify the field and describe the error
- [ ] Navigation is consistent across pages

### Robust (WCAG Principle 4)

- [ ] HTML validates without significant errors
- [ ] ARIA roles, states, and properties are correct
- [ ] Custom components expose name, role, and value
- [ ] Status messages use ARIA live regions

## Email Accessibility Checklist

- [ ] `<html lang="en">` (or appropriate language) is set
- [ ] All `<img>` tags have `alt` attributes
- [ ] Layout tables use `role="presentation"`
- [ ] Minimum font size is 14px (email clients render inconsistently below this)
- [ ] Link text is descriptive (not "click here" or "read more")
- [ ] Heading hierarchy is logical
- [ ] Preheader text provides meaningful preview for screen readers
- [ ] Content reads correctly when tables are linearised
- [ ] Colour contrast meets WCAG AA (4.5:1 for body text)
- [ ] Dark mode tested (add `<meta name="color-scheme" content="light dark">`)

## Monitoring and Continuous Compliance

### Scheduled Audits

Use the bulk audit with a cron job for ongoing monitoring:

```bash
# Create a URL list for monitored pages
cat > ~/.aidevops/reports/accessibility/monitored-urls.txt << 'EOF'
https://example.com
https://example.com/contact
https://example.com/products
EOF

# Run weekly via cron-helper
cron-helper.sh add "accessibility-audit" \
  "0 6 * * 1" \
  "accessibility-helper.sh bulk ~/.aidevops/reports/accessibility/monitored-urls.txt"
```

### Score Tracking

Track accessibility scores over time by comparing Lighthouse JSON reports:

```bash
# Extract score from report
jq -r '.categories.accessibility.score * 100' \
  ~/.aidevops/reports/accessibility/lighthouse_a11y_*.json
```

### CI/CD Integration

Add accessibility checks to build pipelines:

```bash
# Fail build if Lighthouse accessibility score drops below 90
score=$(accessibility-helper.sh lighthouse https://staging.example.com \
  | grep -oP 'Score: \K[0-9]+')
if [[ "$score" -lt 90 ]]; then
  echo "Accessibility score $score% is below 90% threshold"
  exit 1
fi

# Fail build if pa11y finds errors
accessibility-helper.sh pa11y https://staging.example.com WCAG2AA
```

## Tool Selection Guide

| Scenario | Tool | Command |
|----------|------|---------|
| Quick score check | Lighthouse | `accessibility-helper.sh lighthouse <url>` |
| WCAG compliance audit | pa11y | `accessibility-helper.sh pa11y <url> WCAG2AA` |
| Full web audit | Both | `accessibility-helper.sh audit <url>` |
| Email template check | Built-in | `accessibility-helper.sh email <file>` |
| Colour pair validation | Built-in | `accessibility-helper.sh contrast <fg> <bg>` |
| Multi-site monitoring | Bulk | `accessibility-helper.sh bulk <urls-file>` |
| Dynamic SPA content | Playwright | Use `playwright` for JS-rendered pages |
| Real device rendering | Browser tools | `pagespeed-helper.sh` or Litmus/Email on Acid |

## Integration with Other Services

| Service | Integration Point |
|---------|-------------------|
| **Email Testing** (`services/email/email-testing.md`) | Run `email` check alongside design rendering tests |
| **Email Health** (`services/email/email-health-check.md`) | Deliverability + accessibility = complete email audit |
| **PageSpeed** (`tools/browser/pagespeed.md`) | Lighthouse accessibility score included in performance reports |
| **SEO** (`seo/`) | Overlapping concerns: alt text, headings, semantic HTML, lang attribute |
| **Playwright** (`tools/browser/playwright.md`) | Dynamic content testing for SPAs and JS-rendered pages |
| **Content** (`content.md`) | Apply accessibility guidelines during content production |

## Common Remediation Patterns

### Fix: Missing Alt Text

```html
<!-- Before -->
<img src="hero.jpg">

<!-- After: informative image -->
<img src="hero.jpg" alt="Team collaborating around a whiteboard">

<!-- After: decorative image -->
<img src="divider.png" alt="" role="presentation">
```

### Fix: Insufficient Contrast

```bash
# Check current contrast
accessibility-helper.sh contrast '#999999' '#ffffff'
# Result: 2.85:1 — FAIL AA normal text

# Find a passing alternative
accessibility-helper.sh contrast '#595959' '#ffffff'
# Result: 7.00:1 — PASS AAA normal text
```

### Fix: Email Layout Table

```html
<!-- Before -->
<table>
  <tr><td>Content</td></tr>
</table>

<!-- After -->
<table role="presentation" border="0" cellpadding="0" cellspacing="0">
  <tr><td>Content</td></tr>
</table>
```

### Fix: Generic Link Text

```html
<!-- Before -->
<a href="/report">Click here</a> to view your report.

<!-- After -->
<a href="/report">View your accessibility report</a>
```

### Fix: Missing Form Labels

```html
<!-- Before -->
<input type="email" placeholder="Email">

<!-- After -->
<label for="email">Email address</label>
<input type="email" id="email" placeholder="you@example.com">
```

## WCAG 2.2 Additions

WCAG 2.2 (October 2023) adds criteria relevant to this audit:

| Criterion | Level | Description |
|-----------|-------|-------------|
| 2.4.11 Focus Not Obscured (Minimum) | AA | Focused element is at least partially visible |
| 2.4.12 Focus Not Obscured (Enhanced) | AAA | Focused element is fully visible |
| 2.4.13 Focus Appearance | AAA | Focus indicator meets size and contrast requirements |
| 2.5.7 Dragging Movements | AA | Drag operations have single-pointer alternatives |
| 2.5.8 Target Size (Minimum) | AA | Targets are at least 24x24 CSS pixels |
| 3.2.6 Consistent Help | A | Help mechanisms are in consistent locations |
| 3.3.7 Redundant Entry | A | Previously entered info is auto-populated or selectable |
| 3.3.8 Accessible Authentication (Minimum) | AA | No cognitive function test for login |
| 3.3.9 Accessible Authentication (Enhanced) | AAA | No object or image recognition for login |

## Related

- `tools/accessibility/accessibility.md` — Tool reference and WCAG quick reference
- `services/email/email-testing.md` — Email design rendering and delivery testing
- `services/email/email-health-check.md` — Email DNS authentication checks
- `tools/browser/pagespeed.md` — Performance testing (includes accessibility score)
- `tools/browser/playwright.md` — Browser automation for dynamic content testing
- `seo/` — SEO optimization (overlapping accessibility concerns)
