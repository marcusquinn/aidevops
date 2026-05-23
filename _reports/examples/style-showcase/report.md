<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Report Style Showcase

::: report-cover
**Component stress-test for DESIGN.md-backed report styles.** Render this same Markdown through different templates to compare typography, palette, spacing, borders, cards, tables, badges, code blocks, and print profiles.
:::

## Component overview

Use [anchor links](#priority-and-checklist), [appendix links](../llm-visibility-toolbox/report.html), numbered steps, accordions, coloured panels, and source cards in the same canonical Markdown.

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}}
:::

::: stats-strip
::: stat-card
**34**

Renderer templates.
:::
::: stat-card
**16:9**

Slide PDF profile.
:::
::: stat-card
**A4**

Document PDF profile.
:::
::: stat-card
**MD**

Canonical source.
:::
:::

::: action-line
**Review pass:** compare sidebar behaviour, badge wrapping, table fit, and LottieFiles DM Sans rendering.
:::

::: anchor-links
[Table stress](#table-and-source-cards) [Cards](#cards-and-callouts) [Priority](#priority-and-checklist)
:::

---

## Table and source cards

::: facts-table-wrap

| Component | Stress condition | Expected result |
|---|---|---|
| Evidence badge | Long table cell with badge {{evidence:verified}} | Badge stays readable and does not split words. |
| Facts table | Multiple columns with prose | Table remains usable in HTML and constrained in print. |
| Source card | Evidence note near claim | Card is visually distinct from normal paragraphs. |
| Sidebar | Many headings | Sticky TOC remains secondary to content and active link updates. |
:::

::: source-card
### Source sample

This card shows how evidence-led reports separate cited facts from interpretation.
:::

## Cards and callouts

::: info-panel severity=medium
### Info panel

Use info panels for caveats, assumptions, and reading guidance that should not become recommendations.
:::

::: impact-panel severity=high
### Impact panel

Use impact panels to show why a finding changes sequencing, budget, or ownership.
:::

::: evidence-panel severity=low
### Evidence panel

Use evidence panels for source IDs, collection method, confidence, and recheck commands.
:::

::: tactic-card
### Tactic card

- What: compact recommendation summary.
- Why: links action to evidence.
- How: gives implementation shape.
- Verify: names the acceptance check.
:::

::: good-bad
::: good-row
### Good row

Crawlable claims, source IDs, direct answers, and page-type weighting.
:::
::: bad-row
### Bad row

Unsupported claims, hidden content, generic tactics, and missing verification.
:::
:::

::: myth-callout
### Myth

Every page needs the same GEO checklist.

### Fact

Page type determines which tactics are useful, conditional, or noise.
:::

::: accordion title="Accordion details"
Accordions are useful for methodology, caveats, and supplementary notes that should be available without dominating the main narrative.
:::

> Quotes highlight expert evidence, user language, or a decision constraint without turning it into a recommendation.

::: example-card
```text
Render command:
.agents/scripts/report-render-helper.sh render report.md --template lottiefiles --pdf-profile slides-16-9-2 --output report.html
```
:::

## Priority and checklist

::: priority-group priority=high
### High-priority visual checks

Review spacing, table width, no-wrap badges, active TOC highlighting, print CSS, and component contrast.
:::

::: checklist-card

- [x] Same Markdown renders across all templates.
- [ ] LottieFiles preview visibly prioritises DM Sans when the font is installed.
- [x] 16:9 PDF export is landscape.
- [x] HTML preview keeps one sidebar and one main report flow.
:::

::: appendix-links
[Source ledger appendix](../llm-visibility-toolbox/report.md) [Client audit example](../client-ai-search-audit/report.html) [Style preview index](style-previews/index.html)
:::
