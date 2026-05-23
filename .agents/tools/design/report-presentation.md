---
name: report-presentation
description: >
  DESIGN.md guidance for styled Markdown, HTML, and PDF-ready reports. Use when
  designing report templates, evidence-heavy documents, dashboards, SEO/GEO
  reports, or client-ready exports.
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
  task: true
model: sonnet
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Report Presentation Design

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Map report component taxonomy to DESIGN.md tokens and components
  for Markdown, styled HTML, and PDF-ready reports.
- **Use with**: `tools/design/design-md.md` for token format and
  `tools/design/design-md-from-links.md` when deriving a report brand from URLs.
  Also reference `brand-identity.md`, `colour-palette.md`,
  `ui-ux-inspiration.md`, and `ui-ux-catalogue.toon` before creating reusable
  report brand folders or templates.
- **Validation**: `npx @google/design.md lint DESIGN.md`, contrast checks,
  semantic HTML review, print preview, and PDF readability pass.
- **Outputs**: DESIGN.md report tokens, HTML/CSS component guidance, and print
  CSS considerations.

<!-- AI-CONTEXT-END -->

## Report Design Principles

Reports are decision tools. Prioritise scannability, evidence traceability, and
print-safe typography over decorative novelty.

- Put the answer first: executive summary, status, priority, next action.
- Make evidence legible: source cards, citations, confidence badges, timestamps,
  and clear distinction between observed facts and recommendations.
- Use one component language across Markdown, HTML, and PDF so exports do not
  lose meaning.
- Reserve strong colour for status, priority, and action; keep long-form reading
  high-contrast and calm.
- Design every component for narrow screens and paged media from the start.
- Treat light/dark mode as part of the report contract: use observed source
  values where present, otherwise derive an inverse palette with
  `colour-palette.md` and label it as calculated until validated.

## DESIGN.md Token Foundation

Add or verify these token groups in `DESIGN.md`:

| Token group | Report role |
|-------------|-------------|
| `colors.background`, `colors.surface`, `colors.on-surface` | Page, cards, and default text |
| `colors.primary`, `colors.secondary`, `colors.tertiary` | Brand accents, links, chapter markers |
| `colors.success`, `colors.warning`, `colors.error`, `colors.info` | Evidence/status badges and priority states |
| `colors.outline`, `colors.muted`, `colors.highlight` | Dividers, secondary text, pull quotes, search highlights |
| `typography.headline-*` | Cover title, chapter heroes, section headings |
| `typography.body-*`, `typography.label-*`, `typography.code` | Narrative, metadata, badges, examples |
| `spacing.*` | Page rhythm, card padding, table density, print margins |
| `rounded.*` | Cards, badges, code blocks, evidence pills |
| `components.*` | Taxonomy components below |

For theme switching, include both observed and derived roles where possible:

| Role | Light token | Dark/inverse token |
|------|-------------|--------------------|
| Canvas | `colors.background` | `colors.background-dark` |
| Card | `colors.surface` | `colors.surface-dark` |
| Text | `colors.on-surface` | `colors.on-surface-dark` |
| Secondary text | `colors.muted` | `colors.muted-dark` |
| Borders | `colors.outline` | `colors.outline-dark` |
| Accent | `colors.primary` | `colors.primary-dark` |

If the source has no dark mode, mark `*-dark` tokens as calculated and validate
contrast in preview before using them in production exports.

## Component Taxonomy Mapping

Every report component should map to a named `components:` token entry so build
agents can produce consistent Markdown, HTML, and PDF output.

| Taxonomy component | DESIGN.md component token | Required design decisions |
|--------------------|---------------------------|---------------------------|
| Cover/meta | `report-cover`, `report-meta` | Title hierarchy, client/project metadata, date/version, confidentiality marker |
| Executive summary | `report-summary` | Key finding density, status colour, 3-5 bullet rhythm |
| Sticky/table of contents | `report-toc`, `report-toc-active` | Active state, anchor offsets, mobile collapse, print fallback |
| Chapter hero | `report-chapter-hero` | Section label, title, lead paragraph, page-break handling |
| Action line | `report-action-line` | Verb-first action, owner, due date, priority indicator |
| Evidence badge | `report-evidence-badge-*` | Confidence/status colours, label typography, icon/text fallback |
| What/Why/How tactic card | `report-tactic-card`, `report-tactic-step` | Three-part structure, priority, effort/impact chips |
| Code/example card | `report-code-card`, `report-example-card` | Mono type, copy affordance, line wrapping, caption/source |
| Good/bad row | `report-comparison-row-good`, `report-comparison-row-bad` | Paired contrast, accessible icons, avoid colour-only meaning |
| Stats strip | `report-stats-strip`, `report-stat` | Large numerals, labels, trend deltas, mobile wrapping |
| Facts table | `report-facts-table` | Caption, headers, zebra/row hover, numeric alignment, source column |
| Details note | `report-details-note` | Collapsible HTML behaviour, Markdown fallback, print-expanded default |
| Industry card | `report-industry-card` | Segment label, benchmark, opportunity, caveat |
| Priority group | `report-priority-group-*` | Critical/high/medium/low palette, sorting, section intro |
| Checklist | `report-checklist`, `report-checklist-item` | Done/open/blocked states, tap target size, print checkboxes |
| Source card | `report-source-card` | URL/title, author/publisher, access date, evidence quote |
| Myth callout | `report-myth-callout` | Myth/fact contrast, warning tone without alarmism |
| Recommendation | `report-recommendation` | Decision, rationale, expected outcome, next owner |
| Risk/assumption note | `report-risk-note`, `report-assumption-note` | Severity, uncertainty, validation path |
| Timeline/roadmap | `report-timeline`, `report-milestone` | Sequence, dependencies, date labels, page-break-safe rows |
| Appendix | `report-appendix`, `report-footnote` | Smaller but readable type, source density, cross-references |

## Evidence Badge Taxonomy

Use badges to make source strength explicit without overwhelming the reader.

| Badge | Meaning | Typical colour role |
|-------|---------|---------------------|
| `observed` | Directly measured in source, tool output, or screenshot | `info` |
| `verified` | Reproduced by this session or automated check | `success` |
| `inferred` | Reasoned from partial evidence; needs confirmation | `warning` |
| `unsupported` | Claim lacks usable evidence; treat as backlog or remove | `error` |
| `benchmark` | Compared against a known baseline or competitor | `secondary` |
| `recommendation` | Advisory action derived from evidence | `primary` |

Pair every badge with text, not just colour. In print, preserve the label and add
border/shape differences so grayscale output remains meaningful.

## HTML and CSS Guidance

- Use semantic HTML: `<main>`, `<article>`, `<section>`, `<nav>`, `<table>`,
  `<caption>`, `<thead>`, `<tbody>`, `<details>`, `<summary>`, `<figure>`, and
  `<figcaption>` where appropriate.
- Expose source links as real anchors with visible URL or citation labels in PDF.
- Use CSS custom properties generated from DESIGN.md tokens; avoid hard-coded
  one-off report colours.
- For brand-derived report examples, verify `DESIGN.md` includes observed or
  substituted heading/body/code font families, sizes, weights, line heights,
  light palette, and dark/inverse palette where the source exposes one. The
  renderer consumes these token roles directly; missing typography falls back to
  generic defaults and will make style previews look too similar.
- Keep sticky TOC and interactive details progressive: the report remains readable
  when printed, saved to PDF, or viewed without JavaScript.
- Charts need text alternatives: title, summary, data table fallback, and clear
  colour/shape encoding.
- Code blocks should wrap or scroll in HTML, but print with readable line breaks
  and captions.
- Prefer dependency-free chart patterns for committed report HTML. Bklit UI is a
  shadcn registry with attractive chart components, but it requires project
  installation and dependencies; use it for app-integrated dashboards, not as a
  default for portable standalone report exports unless the generated bundle
  vendors all assets locally. Mermaid/LaTeX should have readable source fallbacks.

## PDF and Print Styling

Add print rules alongside screen CSS:

```css
@media print {
  @page { margin: 18mm 16mm; }
  body { color: var(--color-on-surface); background: #fff; font-size: 11pt; }
  a[href]::after { content: " (" attr(href) ")"; font-size: 0.85em; }
  table { break-inside: auto; width: 100%; }
  thead { display: table-header-group; }
  tr, figure, pre, blockquote, .report-card { break-inside: avoid; }
  h1, h2, h3 { break-after: avoid; }
  .no-print, .sticky-toc { display: none !important; }
}
```

Print checks:

- Body text remains readable at 10.5-12pt equivalent.
- Tables repeat headers, preserve captions, and avoid clipped columns.
- Background-dependent badges have borders or labels in grayscale.
- Long URLs/citations wrap without overflowing.
- Chapter heroes and cards avoid orphaned headings and split controls.

## Accessibility Checks

Before shipping a report template or DESIGN.md:

- `npx @google/design.md lint DESIGN.md` returns zero errors.
- Contrast meets WCAG AA: 4.5:1 normal text, 3:1 large text and non-text UI.
- Body copy is at least 16px on screen with comfortable line height.
- Keyboard focus is visible for TOC links, details controls, copy buttons, and
  filters; focus must not rely on colour alone.
- Tables have captions, column headers, row headers where useful, and a responsive
  fallback for narrow screens.
- Status, priority, and evidence states include text labels or icons with labels.
- Print/PDF preserves reading order, source visibility, and grayscale meaning.

## Preview Requirements

Generate a report preview with representative content before handoff:

1. Cover/meta, summary, TOC, at least two chapter heroes.
2. One of each taxonomy component from the mapping table.
3. Light and dark previews if the design supports both (`--theme light` and
   `--theme dark`), with every panel/card/callout checked for inverted surface,
   border, and text tokens.
4. Desktop, mobile, and print/PDF preview screenshots.
5. Contrast and table semantics evidence in the handoff notes.

## Handoff Template

```markdown
## Report Presentation Handoff

- DESIGN.md: `<path>`
- Preview: `<path>`
- Exports checked: Markdown / HTML / PDF
- Validation: `npx @google/design.md lint DESIGN.md` -> <result>
- Accessibility: contrast/body/focus/table/print -> <result>
- Component coverage: all taxonomy components mapped to `components:` tokens
- Implementation notes: <CSS variables, component library, chart/table caveats>
```

## Related

- `tools/design/design-md.md` -- DESIGN.md token schema and validation
- `tools/design/design-md-from-links.md` -- derive report branding from links
- `tools/design/ui-ux-inspiration.md` -- URL study and pattern extraction
- `tools/design/library/_template/preview.html.template` -- preview structure
- `workflows/ui-verification.md` -- browser and screenshot verification
