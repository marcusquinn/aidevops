<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal Agency Brand Style Guide

::: report-cover
**Signal Agency brand guide for usable report and content production.** This specimen is a show-and-tell system for assets, colour, typography, badges, notifications, evidence, recommendations, worker handoff, and export QA.

Signal Agency content should feel **editorial, evidence-led, squared, and decisive**. Use warm paper, black rules, mono provenance, and one terracotta signal accent. Never round the core report components.
:::

::: manifest-card

### Signal Agency production manifest

- **Brand:** Signal Agency
- **Content system:** AI-search audits, client dossiers, evidence packs, roadmap handoffs
- **Shape language:** square cards, strong rules, no soft containers
- **Colour rule:** terracotta is the signal; black carries structure; semantic colours remain muted but visible
- **Writing rule:** lead with the decision, then show the evidence that supports it
- **Export rule:** public examples use placeholders only and suppress browser PDF chrome
:::

## Brand assets and colour roles

::: brand-asset-grid
::: brand-asset-card accent=light

### Primary wordmark on paper

Use on covers, title pages, and formal client handoffs. Keep the mark on warm paper with strong clearspace and one terracotta rule.
:::

::: brand-asset-card accent=dark

### Reverse mark on ink

Use only for intentional chapter openers or high-contrast presentation frames. Do not mix with soft gradients.
:::

::: brand-asset-card accent=light

### Editorial seal

Use for proof points, source-led pages, and dossier dividers. It should feel like a stamp, not an app icon.
:::

::: brand-asset-card accent=dark

### Client lockup zone

Use when pairing Signal Agency with a client or project name. Align on a rule; keep both marks squared and balanced.
:::
:::

::: brand-swatch-grid
::: swatch-card accent=paper

### Warm paper

Default page colour. It makes reports feel reviewed, printed, and evidence-led.
:::

::: swatch-card accent=ink

### Ink black

Primary text, rules, card headers, and table dividers. It creates hierarchy without decoration.
:::

::: swatch-card accent=primary

### Terracotta signal

Use for decisive moments: cover accent, critical decision, or “read this first” marker.
:::

::: swatch-card accent=green

### Verified state

Use for passed checks and protected patterns. Keep it subdued but legible.
:::

::: swatch-card accent=amber

### Warning state

Use for partial evidence, stale facts, and dependencies. It must be visibly different from green and red.
:::

::: swatch-card accent=red

### Critical state

Use for blockers, missing citations, or privacy risk. Pair with a required action.
:::
:::

## Typography and editorial formatting

::: brand-type-scale
::: type-specimen

### Display title

**Client AI-search dossier**

Large Bricolage-style title. Use for covers and chapter openings.
:::

::: type-specimen

### Section heading

**What answer engines can verify**

Use for the question the section answers. Keep it concrete.
:::

::: type-specimen

### Body hierarchy

Use normal body text for evidence. **Bold** the conclusion. *Italic* marks caveats, assumptions, or interpretation.
:::

::: type-specimen

### Mono provenance

Use mono for source IDs, owners, dates, engine names, and verification commands. Provenance must be easy to scan.
:::
:::

::: quote-card
Use quotes for client voice, source excerpts, or reviewer observations. The quote should support a finding, not replace the finding.
:::

## Information tagging badges

Badges are small provenance tags. They sit beside claims, sources, and table cells. They are **not** notifications and should not occupy a whole page alone.

::: badge-row
**Evidence:** {{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}}

**Priority:** {{badge:critical}} {{badge:high}} {{badge:medium}} {{badge:low}}
:::

::: facts-table-wrap

| Badge | Purpose | Use example | Signal Agency rule |
|---|---|---|---|
| {{evidence:verified}} | Directly observed evidence | “AI Overview cites the comparison page” | Attach source ID |
| {{evidence:partial}} | Mixed or incomplete support | “Gemini sees pricing but misses warranty” | Explain the gap |
| {{evidence:inferred}} | Judgement from pattern | “Likely schema/entity mismatch” | Keep caveat visible |
| {{evidence:missing}} | No evidence captured | “No source card for claim” | Convert to an action |

:::

## Message states and notifications

::: notification-grid
::: info-panel severity=critical

### Critical dossier alert

**Purpose:** stop the reader and require action. Use for privacy exposure, missing source IDs, or evidence that invalidates the recommendation.

**Example:** “Raw prompt transcript appears in the public export. Replace with a redacted source summary.”
:::
::: info-panel severity=high

### Warning dossier note

**Purpose:** highlight risk that affects confidence. Use for stale citations, partial retrieval, or owner ambiguity.

**Example:** “Two engines cite the old service name; update corroborating profiles before the next crawl.”
:::
::: info-panel severity=medium

### Method note

**Purpose:** explain how evidence was collected or scoped.

**Example:** “Prompts were run from a clean browser profile and compared against first-fetch HTML.”
:::
::: info-panel severity=low

### Preserved pattern

**Purpose:** mark a verified pattern to keep.

**Example:** “Source IDs now appear beside every factual recommendation.”
:::
:::

## Report component show-and-tell

::: stats-strip
::: kpi-card
**3/5**

Engines with at least partial visibility. **Source:** C001.
:::
::: kpi-card
**27**

Evidence references captured. **Source:** ledger.
:::
::: kpi-card
**6**

Roadmap items sized. **Source:** priorities.
:::
::: kpi-card
**0**

Private URLs in public export. **Source:** privacy check.
:::
:::

::: visibility-bars
AI Overviews — 78%

Gemini — 54%

ChatGPT — 41%

AI Mode — 38%

Perplexity — 9%
:::

::: facts-table-wrap

| Component | Purpose | Signal Agency treatment | Example content |
|---|---|---|---|
| Manifest | Scope and evidence rules | Square field block with ink rule | “Raw transcripts stored securely” |
| KPI card | Executive metric | Huge numeral, short source line | “3/5 engines visible” |
| Source ledger | Claim traceability | One width, dotted row rules | C001 — prompt capture batch |
| Brief card | Worker handoff | Light ruled panel, mono fields | Task / files / acceptance / verify |

:::

::: ledger-list
C001 — Prompt capture batch — **High confidence**; raw transcripts stored securely.

C002 — Rendered crawl — **High confidence**; confirms first-fetch visibility.

C003 — Analytics export — **Medium confidence**; prioritises commercial pages.

C004 — Parity review — **Medium confidence**; checks third-party fact drift.
:::

## Recommendation and handoff patterns

::: priority-card priority=critical

### P0 retrieval blocker {{evidence:verified}}

Use when one finding needs executive visibility, owner, due date, source IDs, and verification.

**Owner:** Editorial. **Due:** 2026-W23. **Verify:** C001 and C002 show first-fetch retrieval.
:::

::: priority-card priority=high

### P1 evidence proximity {{evidence:partial}}

Use when facts exist but are too far from the claim, table, or source card.

**Owner:** Content. **Due:** 2026-W25. **Verify:** source IDs appear beside each claim.
:::

::: priority-card status=done

### Resolved pattern {{evidence:verified}}

Use for shipped work that should be protected in the next iteration.

**Owner:** Engineering. **Verified:** C001. **Preserve:** no private URL appears in public PDFs.
:::

::: good-bad
::: good-row

### Preserve

- **Source IDs** beside factual claims.
- Direct-answer opening in first-fetch HTML.
- Clear comparison criteria.
:::
::: bad-row

### Fix

- Client-rendered critical facts.
- Unsupported superlatives.
- Raw evidence in public artefacts.
:::
:::

::: brief-card

### Worker-ready brief

**Task:** Move critical comparison facts into crawlable HTML and attach source IDs.

**Files:** comparison template, source-card component, pricing facts module.

**Acceptance:** direct answer, source IDs, updated date, and criteria table appear in first-fetch HTML.

**Verification:** rerun per-engine prompt set separately and compare citations.
:::

::: example-card title="Signal Agency light code panel"

```text
Do: put source IDs beside factual claims.
Do not: publish raw transcripts, local paths, or private URLs in public reports.
```

:::

::: privacy-note
**Public artifact rule**

Signal Agency public examples must use placeholders only. Raw transcripts, screenshots, private URLs, client names, and local paths stay in approved secure storage.
:::

::: version-summary
Signal Agency brand style guide specimen · usable production guide · public-safe placeholder content
:::
