<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Report Style Showcase

Evidence-based report components for AI-search, SEO/GEO, and operational audit exports.

By [Marcus Quinn](https://github.com/marcusquinn).

::: report-cover
Internal toolkit · May 2026 · v4

**Component stress-test for DESIGN.md-backed report styles.** Render this same Markdown through different templates to compare typography, palette, spacing, borders, cards, tables, badges, code blocks, and print profiles.

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
:::

## Executive summary

This showcase demonstrates the report components expected in the LLM Visibility Toolbox examples: a non-numbered executive summary, numbered H2 chapters, plain H3 subheadings, sources grouped by type, badge keys, checklists, code/block templates, callouts, accordions, and a version summary.

::: badge-key
{{badge:rct}} Peer-reviewed paper or controlled comparison with documented methodology.

{{badge:strong}} Large primary-data analysis from an independent source.

{{badge:vendor}} Vendor-published study with methodology, but commercial conflict of interest.

{{badge:practitioner}} Practitioner report or anecdote, often without a control group.

{{badge:hygiene}} Technical baseline that is not experimentally measured but follows from how the bots work.
:::

::: accordion title="What changed in v4"
Schema was downgraded after controlled evidence; engine divergence is now structural; source sections are grouped by evidence type; reports keep Mermaid and LaTeX as readable fallbacks unless local renderers pre-render them.
:::

::: action-line
**Action:** review the numbered chapters below and compare the generated HTML against the source Toolbox patterns.
:::

## Why this matters now

Use [anchor links](#priority-and-checklist), [appendix links](../llm-visibility-toolbox/report.html), numbered steps, accordions, coloured panels, and source cards in the same canonical Markdown.

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}}
:::

Evidence values should read as plain **Evidence:** text followed by a colour-coded mini badge for the value only.

::: anchor-links
[Table stress](#table-and-source-cards) [Cards](#cards-and-callouts) [Priority](#priority-and-checklist)
:::

## Highest impact, most validated

Use plain narrative and bullets when that is clearer than a panel. Panels are reserved for warnings, action blocks, source cards, or high-emphasis evidence.

### Earned media on third-party platforms {{badge:strong}}

Six converging studies point to third-party mentions as a stronger AI visibility signal than isolated owned-page edits.

- Build a quarterly cadence across trade press, community, video, and partner surfaces.
- Pair each campaign with source IDs and prompt reruns.
- Verify movement separately in AIO, Gemini, ChatGPT, AI Mode, and Perplexity.

::: action-line
**Action:** coordinate one trade article, one community thread, one video transcript, and one partner citation within the same quarter.
:::

A plain bullet section should remain plain:

- Robots.txt and crawlability check for key AI bots.
- Render test with a representative answer-engine user agent.
- Schema audit on priority pages.
- Prompt list from Search Console, support tickets, and customer interviews.
- Baseline share of voice, citation rate, and sentiment per engine.

## On-page content tactics

::: facts-table-wrap

| Component | Stress condition | Expected result |
|---|---|---|
| Evidence badge | Long table cell with badge {{evidence:verified}} | Badge stays readable and does not split words. |
| Facts table | Multiple columns with prose | Table remains usable in HTML and constrained in print. |
| Source card | Evidence note near claim | Card is visually distinct from normal paragraphs. |
| Sidebar | Many headings | Sticky TOC remains secondary to content and active link updates. |
:::

## Technical tactics

::: info-panel severity=medium
### Info panel

Use info panels for caveats, assumptions, and reading guidance that should not become recommendations.
:::

::: impact-panel severity=high
### Impact panel

**Why this changes the plan:** a high-impact finding changes sequencing, budget, owner, or acceptance criteria.
:::

::: action-panel severity=high
### Action panel

**Next action:** turn the finding into a concrete implementation step with owner, proof path, and rerun command.
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

::: accordion title="How to read this document (evidence badges)"
Every tactic carries a badge. Use RCT/academic for controlled research, strong primary data for large independent data, vendor study where methodology exists but incentives are commercial, practitioner for field evidence, and hygiene for baseline technical work.
:::

::: accordion title="Key methodology caveat"
A visible uplift in one engine is not proof of universal AI visibility. Keep AIO, Gemini, ChatGPT, AI Mode, and Perplexity separate until the closing synthesis.
:::

> Quotes highlight expert evidence, user language, or a decision constraint without turning it into a recommendation.

::: block-template title="Author block template"
```text
Written by Dr. Jane Doe, PhD
Principal Data Scientist, ExampleCo

Jane led the data platform team from 2019 to 2024 and now researches LLM retrieval.

LinkedIn | Google Scholar | Personal site
```
:::

::: example-card title="Render command"
```text
.agents/scripts/report-render-helper.sh render report.md --template lottiefiles --pdf-profile slides-16-9-2 --output report.html
```
:::

::: example-card title="Mermaid fallback"
```mermaid
flowchart LR
  SourceLedger --> Finding
  Finding --> Recommendation
  Recommendation --> Verification
```
:::

::: example-card title="LaTeX fallback"
```latex
\text{LLM visibility} = \alpha citations + \beta mentions + \gamma retrieval - \delta decay
```
:::

Inline LaTeX fallback: {{latex:\text{visibility} = \alpha citations + \beta mentions + \gamma retrieval}}.

::: bar-chart
Citation readiness — 72%
Third-party corroboration — 58%
Retrieval eligibility — 81%
:::

## Off-page and authority

Authority work belongs outside the site as much as on it: profile parity, trusted third-party mentions, practitioner credentials, and community proof all support retrieval and citation decisions.

## Format and experimental tactics

::: callout
### SEO myths called out

Claims that circulate widely but cannot be traced to a primary source, or are contradicted by controlled evidence, should be called out explicitly.

**“Schema markup alone creates citation uplift.”** Contradicted by controlled or near-controlled studies; ship schema as hygiene.

**“Longer content always gets cited more.”** Engine-dependent; content depth helps only when it improves answer density and source usefulness.
:::

## Measurement and reporting

::: priority-group priority=high
### High-priority visual checks

Review spacing, table width, no-wrap badges, active TOC highlighting, print CSS, and component contrast.
:::

::: checklist-card
### Refresh checklist per page

- [ ] Replace at least one statistic with newer data.
- [ ] Add or revise one example.
- [ ] Remove outdated tool or vendor references.
- [ ] Update screenshots if UI has changed.
- [ ] Update `dateModified` in schema.
- [ ] Add visible “Last updated” line.
:::

## What does not work

::: callout
### Combined finding

AI is now a discovery layer, but engines disagree on sources. Tracking only mentions or only citations misses the retrieval gap. Keep the final synthesis short, source-backed, and tied to the next action.
:::

## Productizing for clients

Use the same Markdown-first report structure for one-off audits, monthly retainers, lead magnets, and routine handoffs. Keep deterministic evidence collection separate from interpretation.

## Case studies

::: case-study-card
### Industrial manufacturer

**Result:** monthly AI referral traffic grew from near-zero to a measurable assisted-conversion channel.

**Tactics applied:** direct-answer page restructure, original technical benchmarks, schema hygiene, and trade-publication mentions.
:::

::: case-study-card
### Healthcare comparison site

**Result:** citations appeared across Google AIO, ChatGPT, and Gemini after entity facts and expert review were made visible.

**Tactics applied:** YMYL author bylines, source-backed comparison tables, third-party profile parity, and prompt reruns.
:::

## Sources

::: sources-layout
::: sources-group
::: source-title
Primary evidence
:::
::: source-card
### Source A
Prompt capture, crawl export, and source ledger row.
:::
::: source-card
### Source B
Third-party corroboration and profile parity note.
:::
:::
::: sources-group
::: source-title
Supplementary evidence
:::
::: source-card
### Source C
Appendix file, screenshot reference, or companion report.
:::
:::
:::

::: source-list
::: source-title
Peer-reviewed papers and academic studies
:::
::: source-item
### GEO: Generative Engine Optimization
The first peer-reviewed baseline. Tactics tested on 10k queries.
:::
::: source-item
### News source citing patterns in AI search systems
Top source concentration and citation dynamics.
:::
::: source-title
Q2 2026 field evidence
:::
::: source-item
### Ahrefs: schema markup has no impact on AI visibility
1,885 vs 4,000 controls, difference-in-differences. Source used to downgrade schema from growth lever to hygiene.
:::
::: source-item
### Growth memo: the consensus gap
Only a small share of cited URLs overlap across engines; engine-specific reporting is required.
:::
::: source-item
### G2: the answer economy research
B2B buyers increasingly start with answer engines, so reports separate discovery, shortlist, and conversion evidence.
:::
:::

## Appendices

::: appendix-links
[Source ledger appendix](../llm-visibility-toolbox/report.md) [Client audit example](../client-ai-search-audit/report.html) [Example browser](../index.html)
:::

::: version-summary
V4 · compiled May 2026 from 70+ primary sources · internal toolkit
:::
