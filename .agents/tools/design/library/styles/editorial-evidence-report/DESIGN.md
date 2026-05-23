---
version: alpha
name: Editorial Evidence Report
description: Premium print-safe report profile for evidence-led LLM visibility, SEO/GEO, audit, and advisory reports with editorial typography and reusable report primitives
colors:
  primary: "#111827"
  secondary: "#4B5563"
  tertiary: "#2563EB"
  neutral: "#F8F6F1"
  surface: "#FFFFFF"
  on-surface: "#1F2937"
  error: "#B42318"
  paper: "#F8F6F1"
  paper-raised: "#FFFDF8"
  ink: "#111827"
  ink-muted: "#4B5563"
  ink-soft: "#6B7280"
  rule: "#D8D2C4"
  rule-strong: "#B8AE9C"
  accent-blue: "#2563EB"
  accent-amber: "#B7791F"
  accent-green: "#147A4A"
  accent-red: "#B42318"
  accent-violet: "#6D28D9"
  good: "#147A4A"
  good-surface: "#EAF7EF"
  bad: "#B42318"
  bad-surface: "#FDECEC"
  code-surface: "#111827"
  code-text: "#E5E7EB"
  code-accent: "#93C5FD"
typography:
  headline-display:
    fontFamily: "'Newsreader', Georgia, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 64px
    fontWeight: 600
    lineHeight: 1.05
    letterSpacing: -0.035em
  headline-lg:
    fontFamily: "'Newsreader', Georgia, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 44px
    fontWeight: 600
    lineHeight: 1.12
    letterSpacing: -0.025em
  headline-md:
    fontFamily: "'Newsreader', Georgia, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 30px
    fontWeight: 600
    lineHeight: 1.18
    letterSpacing: -0.015em
  body-lg:
    fontFamily: "'IBM Plex Sans', system-ui, -apple-system, 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.7
  body-md:
    fontFamily: "'IBM Plex Sans', system-ui, -apple-system, 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.65
  body-sm:
    fontFamily: "'IBM Plex Sans', system-ui, -apple-system, 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.55
  label-md:
    fontFamily: "'IBM Plex Sans', system-ui, -apple-system, 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: 12px
    fontWeight: 700
    lineHeight: 1.35
    letterSpacing: 0.08em
  code-md:
    fontFamily: "'IBM Plex Mono', 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace"
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.55
rounded:
  none: 0px
  sm: 4px
  md: 8px
  lg: 14px
  xl: 22px
  full: 9999px
spacing:
  unit: 8px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 32px
  xl: 64px
  gutter: 28px
  margin: 56px
components:
  cover-meta:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    typography: "{typography.headline-display}"
    border: "1px solid {colors.rule}"
    padding: 64px
  sticky-toc:
    backgroundColor: "rgba(255, 253, 248, 0.94)"
    textColor: "{colors.ink-muted}"
    typography: "{typography.body-sm}"
    rounded: "{rounded.lg}"
    border: "1px solid {colors.rule}"
    padding: 16px
  chapter-hero:
    backgroundColor: "{colors.paper-raised}"
    textColor: "{colors.ink}"
    typography: "{typography.headline-lg}"
    border: "1px solid {colors.rule}"
    padding: 32px
  action-line:
    backgroundColor: "#111827"
    textColor: "#FFFFFF"
    typography: "{typography.body-md}"
    rounded: "{rounded.md}"
    padding: 16px 20px
  evidence-badge:
    backgroundColor: "#EAF2FF"
    textColor: "#1D4ED8"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 4px 10px
  tactic-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
    border: "1px solid {colors.rule}"
    padding: 24px
  code-example:
    backgroundColor: "{colors.code-surface}"
    textColor: "{colors.code-text}"
    typography: "{typography.code-md}"
    rounded: "{rounded.md}"
    padding: 18px
  facts-table:
    backgroundColor: "{colors.paper-raised}"
    textColor: "{colors.ink}"
    typography: "{typography.body-sm}"
    border: "1px solid {colors.rule}"
    padding: 0
---

<!--
DESIGN.md — AI-readable design system document
Format: google-labs-code/design.md v0.1.0 (format version: alpha)
Spec: https://github.com/google-labs-code/design.md/blob/main/docs/spec.md
Validate: npx @google/design.md lint DESIGN.md
-->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Editorial Evidence Report

## 1. Overview

Editorial Evidence Report is a premium report profile for evidence-led advisory work: LLM visibility reports, technical SEO/GEO audits, market research briefs, and implementation roadmaps. It combines a print-first editorial voice with dense, structured evidence components.

The style should feel like a serious analyst report: warm paper, crisp ink, visible rules, restrained accents, readable long-form typography, and scannable evidence primitives. The default mode is light because reports are commonly exported to PDF, printed, reviewed in board packs, and shared as attachments. Dark mode may be added later as a token override, not as the canonical baseline.

**Key characteristics:**
- **Mood:** editorial, analytical, premium, calm, evidence-first
- **Background:** near-white warm paper `#F8F6F1` with raised white report surfaces
- **Typography:** Newsreader headlines, IBM Plex Sans body, IBM Plex Mono code/data
- **Rules:** visible but soft separators using warm grey ink and paper tones
- **Density:** high information density with deliberate spacing and strong section hierarchy
- **Print posture:** page-break-aware cards, visible URLs/citations, sticky UI disabled for print

## 2. Colors

### Core palette

| Role | Value | Usage |
|------|-------|-------|
| Paper | `#F8F6F1` | Body background, print canvas |
| Paper raised | `#FFFDF8` | Cover, cards, chapter panels |
| Surface | `#FFFFFF` | Tables, cards, inset notes |
| Ink | `#111827` | Primary text and report titles |
| Ink muted | `#4B5563` | Summaries, metadata, secondary copy |
| Ink soft | `#6B7280` | Captions, table notes, disabled states |
| Rule | `#D8D2C4` | Borders, dividers, table rules |
| Rule strong | `#B8AE9C` | Active navigation, cover rules, print separators |

### Multi-accent palette

| Accent | Value | Usage |
|--------|-------|-------|
| Blue | `#2563EB` | Links, primary evidence, information |
| Amber | `#B7791F` | Warnings, estimates, effort |
| Green | `#147A4A` | Good states, wins, validated actions |
| Red | `#B42318` | Bad states, risks, errors |
| Violet | `#6D28D9` | Model/LLM-specific notes, strategy |

### Semantic and code palette

| Role | Value | Usage |
|------|-------|-------|
| Good | `#147A4A` on `#EAF7EF` | Good rows, positive deltas, pass states |
| Bad | `#B42318` on `#FDECEC` | Bad rows, risk deltas, fail states |
| Code surface | `#111827` | Code/example cards |
| Code text | `#E5E7EB` | Code body text |
| Code accent | `#93C5FD` | Highlighted tokens, inline labels |

### Evidence badge colours

| Badge | Surface | Text | Use |
|-------|---------|------|-----|
| RCT | `#EAF7EF` | `#147A4A` | Randomised/controlled or highest-confidence research evidence |
| Strong | `#EAF2FF` | `#1D4ED8` | Direct observed or strong third-party evidence |
| Vendor | `#F4ECFF` | `#6D28D9` | Platform documentation, vendor claims, API docs |
| Practitioner | `#FFF5DB` | `#92400E` | Experienced implementation guidance and field observations |
| Hygiene | `#F3F4F6` | `#374151` | Standard best-practice, baseline checks, compliance hygiene |

### Future dark-mode token notes

Reports may expose a light/dark toggle later. Keep component names stable and override only token values: paper becomes near-black, paper-raised becomes charcoal, ink becomes warm white, rules become translucent white, and semantic badge surfaces become low-saturation dark tints. Print export must continue to force the light token set.

## 3. Typography

**Font families:**
- **Headings:** `"Newsreader", Georgia, "Times New Roman", "Noto Serif", serif`
- **Body/UI:** `"IBM Plex Sans", system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif`
- **Code/data:** `"IBM Plex Mono", "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace`

| Role | Font | Size | Weight | Line-height | Usage |
|------|------|------|--------|-------------|-------|
| Display | Newsreader | 64px | 600 | 1.05 | Cover titles and opening statements |
| H1 | Newsreader | 44px | 600 | 1.12 | Chapter hero headings |
| H2 | Newsreader | 30px | 600 | 1.18 | Major report sections |
| H3 | IBM Plex Sans | 20px | 700 | 1.3 | Component titles |
| Body large | IBM Plex Sans | 18px | 400 | 1.7 | Executive summaries |
| Body | IBM Plex Sans | 16px | 400 | 1.65 | Main copy |
| Small | IBM Plex Sans | 14px | 400 | 1.55 | Captions and sidebars |
| Label | IBM Plex Sans | 12px | 700 | 1.35 | Badges and metadata, uppercase |
| Code | IBM Plex Mono | 13px | 400 | 1.55 | Code/example cards and data snippets |

## 4. Layout

### Spacing scale

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Badge internals, tight icon gaps |
| `--space-2` | 8px | Inline clusters, table cell micro-gaps |
| `--space-3` | 16px | Card internal rhythm |
| `--space-4` | 24px | Standard component padding |
| `--space-5` | 32px | Section groups, chapter panels |
| `--space-6` | 48px | Report page gutters |
| `--space-7` | 64px | Cover and chapter vertical spacing |
| `--space-8` | 96px | Major report breaks |

### Grid and page structure

- Use a 12-column report grid with 28px gutters on desktop.
- Main article content spans 8 columns; sticky TOC/metadata spans 3 columns.
- Components may become full-width for facts tables, source lists, and stats strips.
- Mobile collapses to one column; sticky TOC becomes a normal section.
- Print uses a single flow with page-break rules and no sticky positioning.

## 5. Elevation & Depth

| Level | Name | Shadow | Usage |
|-------|------|--------|-------|
| 0 | Flat | `none` | Most print-safe report elements |
| 1 | Paper lift | `0 1px 2px rgba(17, 24, 39, 0.06)` | Cards and tables on screen |
| 2 | Navigation lift | `0 12px 32px rgba(17, 24, 39, 0.10)` | Sticky TOC only, screen mode |

Depth must never be the only separator; retain borders/rules for print fidelity.

## 6. Shapes

| Token | Value | Usage |
|-------|-------|-------|
| None | `0px` | Tables, print rules |
| Small | `4px` | Inline code, small labels |
| Medium | `8px` | Badges, notes, action lines |
| Large | `14px` | Tactic cards, source cards |
| Extra large | `22px` | Cover and chapter panels |
| Full | `9999px` | Evidence and priority pills |

## 7. Components

Style every canonical report taxonomy component:

- **Cover/meta:** warm paper panel with large Newsreader title, meta grid, confidentiality label, and report summary.
- **Sticky TOC:** right or left rail on desktop with active rule, compact labels, and accessible anchor links; normal block in print/mobile.
- **Chapter hero:** raised editorial panel with kicker, title, summary, priority, and evidence badges.
- **Action line:** high-contrast strip beginning with a verb; includes owner, impact, effort, and due metadata.
- **Evidence badges:** compact uppercase pills for RCT, Strong, Vendor, Practitioner, and Hygiene evidence levels.
- **Tactic card:** What/Why/How grid with priority, impact, effort, and evidence.
- **Example/code card:** dark code surface with IBM Plex Mono and copy-safe status.
- **Good/bad rows:** two-column contrast rows using semantic green/red surfaces and neutral reasoning text.
- **Stats strip:** KPI cards with value, unit, delta, period, and source note.
- **Facts table:** dense ruled table with sticky-compatible headers on screen and repeated headers in print when the renderer supports them.
- **Details note:** bordered aside for caveats, assumptions, implementation notes, and sensitivity warnings.
- **Industry card:** vertical-specific context, pattern, implication, and applicability boundary.
- **Priority group:** grouped action list sorted critical, high, medium, low.
- **Checklist:** status-aware task list with owner and evidence reference.
- **Source card:** citation/source appendix card with source id, title, type, observed date, summary, and sensitivity.
- **Myth callout:** myth vs reality correction with restrained accent and supporting evidence.
- **Print CSS:** remove sticky behaviour, avoid breaking cards/tables badly, expose URLs/citations, and force light tokens.

## 8. Do's and Don'ts

**Do:**
- Lead every recommendation with the evidence strength and intended action.
- Preserve readable Markdown semantics before adding CSS embellishment.
- Use rules, typography, and spacing instead of heavy gradients or decorative effects.
- Keep charts, tables, and source cards printable in grayscale.
- Make badges descriptive in text, not colour-only.

**Don't:**
- Rely on sticky navigation or hover states for critical report meaning.
- Use dark mode for print output.
- Put raw private paths, secret values, or sensitive source identifiers in public report examples.
- Overuse accent colours; reserve them for evidence type, status, and priority.

## 9. Responsive Behaviour

- `>=1200px`: report grid with sticky TOC and 8-column content well.
- `768-1199px`: two-column grid when space allows; TOC remains visible but not overly tall.
- `<768px`: single column, TOC unpinned, cards stack, tables scroll horizontally on screen.
- `print`: single flow, fixed margins, sticky disabled, links and citations exposed.

## 10. Agent Prompt Guide

When applying this style, generate semantic report HTML first: landmarks, headings, lists, tables, and labelled sections. Then apply the CSS classes from `.agents/templates/reports/llm-visibility-report.css`. Include evidence badges and source cards for externally supportable claims. Prefer concise analyst copy with source-aware wording over marketing language.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md spec: https://github.com/google-labs-code/design.md
-->
