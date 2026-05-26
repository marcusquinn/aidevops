---
version: alpha
name: "Signal Agency"
description: "Editorial, evidence-first agency report design system for AI-search audit documents."
colors:
  background: "#ECEEEB"
  surface: "#FFFFFF"
  on-surface: "#0B0D0A"
  muted: "#5A605C"
  outline: "#0B0D0A"
  primary: "#B93A19"
  primary-container: "#F3DED5"
  paper-alt: "#E2E5E1"
  paper-raised: "#F5F6F4"
  outline-soft: "#C9CDC9"
  outline-hair: "#D9DCD8"
  signal-ink: "#6B2415"
  positive: "#23784C"
  positive-container: "#E8F4EC"
  negative: "#B83A22"
  negative-container: "#F7E6E0"
  warning: "#78621B"
  warning-container: "#F3ECD6"
  info: "#3068A3"
  info-container: "#E5EEF8"
  neutral: "#5A605C"
  code-background: "#F5F6F4"
  code-on-background: "#0B0D0A"
  code-accent: "#B93A19"
  info-background: "#E5EEF8"
  impact-background: "#F3DED5"
  evidence-background: "#F5F6F4"
  myth-background: "#F7E6E0"
  good-background: "#E8F4EC"
  bad-background: "#F7E6E0"
typography:
  headline-display:
    fontFamily: '"Bricolage Grotesque", ui-sans-serif, system-ui, sans-serif'
    fontSize: 88px
    fontWeight: "700"
    lineHeight: "0.94"
    letterSpacing: -0.045em
    fontVariation: '"opsz" 96, "wdth" 95'
  headline-md:
    fontFamily: '"Bricolage Grotesque", ui-sans-serif, system-ui, sans-serif'
    fontSize: 34px
    fontWeight: "600"
    lineHeight: "1.05"
    letterSpacing: -0.035em
    fontVariation: '"opsz" 72, "wdth" 100'
  body-md:
    fontFamily: '"Instrument Sans", ui-sans-serif, system-ui, sans-serif'
    fontSize: 16px
    fontWeight: "400"
    lineHeight: "1.55"
    fontFeature: '"ss01", "cv01"'
  body-sm:
    fontFamily: '"Instrument Sans", ui-sans-serif, system-ui, sans-serif'
    fontSize: 14px
    fontWeight: "400"
    lineHeight: "1.45"
  label-md:
    fontFamily: '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace'
    fontSize: 11px
    fontWeight: "500"
    lineHeight: "1.2"
    letterSpacing: 0.08em
  code-md:
    fontFamily: '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace'
    fontSize: 12px
    fontWeight: "500"
    lineHeight: "1.55"
    letterSpacing: 0.04em
rounded:
  none: 0px
  sm: 1px
  md: 2px
  lg: 0px
  xl: 0px
spacing:
  1: 4px
  2: 8px
  3: 12px
  4: 16px
  5: 24px
  6: 32px
  7: 48px
  8: 64px
  9: 96px
components:
  report-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
  report-card-header:
    backgroundColor: "{colors.on-surface}"
    textColor: "{colors.paper-raised}"
    typography: "{typography.label-md}"
    rounded: "{rounded.none}"
  evidence-badge:
    backgroundColor: "{colors.primary-container}"
    textColor: "{colors.signal-ink}"
    typography: "{typography.label-md}"
    rounded: "{rounded.sm}"
  action-line:
    backgroundColor: "{colors.background}"
    textColor: "{colors.on-surface}"
  table-report:
    backgroundColor: "{colors.background}"
    textColor: "{colors.on-surface}"
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Signal Agency

Signal Agency is an editorial evidence-report system for agency AI-search audits. It treats reports as research dossiers: warm paper, black ink, hairline rules, tabular figures, square components, source IDs, and one confident terracotta signal accent.

## Chapters

| File | Contents |
|------|----------|
| [01-visual-theme.md](01-visual-theme.md) | Paper/ink/signalling principles and document mood |
| [02-color-palette.md](02-color-palette.md) | Core colours, semantic states, evidence/priority roles |
| [03-typography.md](03-typography.md) | Bricolage Grotesque, Instrument Sans, JetBrains Mono scale |
| [04-components.md](04-components.md) | Evidence tags, stat strips, tables, source ledgers, callouts, dossier cards |
| [05-layout.md](05-layout.md) | 12-column grid, spacing scale, rules, report/print structure |
| [06-depth-elevation.md](06-depth-elevation.md) | Flat depth, borders, shadows, dossier chrome |
| [07-dos-and-donts.md](07-dos-and-donts.md) | Application rules and anti-patterns |
| [08-responsive.md](08-responsive.md) | Mobile, tablet, desktop, and print/PDF behaviour |
| [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Reproduction prompts and renderer handoff |

## Quick Reference

- **Mood**: “Signal, not noise” — research dossier, editorial audit, agency evidence pack.
- **Accent**: terracotta signal `#B93A19`; use for decisions, P0/critical, the cover emphasis, and small glyphs only.
- **Background/surface**: warm paper `#ECEEEB`, alternate paper `#E2E5E1`, raised paper `#F5F6F4`, white cards only when contrast needs it.
- **Text/rules**: near-black ink `#0B0D0A`; rules carry layout hierarchy.
- **Typography**: Bricolage Grotesque display, Instrument Sans body, JetBrains Mono metadata/data. These are available through Google Fonts; use linked web fonts or self-hosted WOFF2 files with bundled font licence files when production embedding requires offline/privacy-safe rendering.
- **Shape/depth**: square corners, 0px radii for report containers, tables, code blocks, cards, buttons, and copy controls; depth comes from rules, surface changes, and occasional hard offset shadows.
- **Code blocks**: light paper code panels (`#F5F6F4` background, `#0B0D0A` ink, `#B93A19` labels/accent) with square corners. Avoid dark terminal blocks unless the surrounding artifact is explicitly dark-mode.
- **Grid**: 12 columns, max width 1280px, responsive gutter `20-56px`, body copy under 56ch.
- **Evidence grammar**: verified/partial/inferred/missing badges, source IDs, priority squares, confidence bars, trend glyphs.

## Source Review

- **Review date**: 2026-05-25
- **Source**: user-provided local HTML style-guide specimen titled “Signal — Design System for AI Search Audit Reports”.
- **Prompt-guard**: `prompt-guard-helper.sh scan-file` returned CLEAN.
- **Observed fonts**: Bricolage Grotesque, Instrument Sans, JetBrains Mono via Google Fonts stylesheet in the source specimen. Fontsource package metadata reports all three as `OFL-1.1`; retain each upstream `OFL.txt` if bundling/self-hosting font binaries.
- **Observed token facts**: CSS custom properties for paper, ink, soft rules, terracotta signal, semantic state hues, type scale, 4px spacing base, 1280px max page, responsive gutters.
- **Observed component taxonomy**: masthead, cover, swatches, type rows, pills, evidence tags, priority markers, stats, tables, source ledger, callouts, preserve/fix split, action line, implementation brief, dossier cards, KPI cards, LEDs, stamps, tabs, checklist, bar visualisation, footer.
- **Rule**: source facts inform this DESIGN.md; renderer tokens use accessible sRGB approximations for OKLCH source colours and web-safe fallbacks when remote fonts are unavailable.
