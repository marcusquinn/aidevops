<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Report Component Taxonomy

Canonical contract for report agents, report templates, renderers, and SEO/GEO outputs. Keep this reference on-demand; do not duplicate it in always-loaded guidance.

## Evidence Badge Model

Every recommendation, claim, statistic, and tactic card should carry at least one evidence badge when the report makes an externally supportable claim.

| Badge | Use for | Required evidence fields | Rendering notes |
|-------|---------|--------------------------|-----------------|
| `observed` | First-party crawl, audit, screenshot, log, analytics, search console, or manual review observations | `source_id`, `source_title`, `source_type`, `observed_date`, `claim_supported`, `confidence`, `sensitivity` | Show as the strongest badge; pair with the inspected URL, artefact, or dataset label when safe. |
| `sourced` | Third-party source, vendor documentation, public research, standards, or cited article | `source_id`, `source_title`, `source_type`, `observed_date`, `claim_supported`, `confidence`, `sensitivity` | Link to the source card or citation list; avoid inline raw URLs in print-first layouts. |
| `benchmark` | Competitive comparison, industry baseline, SERP/LLM mention comparison, or before/after metric | `source_id`, `source_title`, `source_type`, `observed_date`, `claim_supported`, `confidence`, `sensitivity` | Render with comparison context: peer set, time window, and metric unit. |
| `inferred` | Modelled conclusion from multiple signals where no single source proves the whole claim | `source_id`, `source_title`, `source_type`, `observed_date`, `claim_supported`, `confidence`, `sensitivity` | Visually softer than direct evidence; include the inputs that support the inference. |
| `estimate` | Forecast, projection, sizing, effort, cost, lift, or priority score | `source_id`, `source_title`, `source_type`, `observed_date`, `claim_supported`, `confidence`, `sensitivity` | Label assumptions clearly; show ranges instead of false precision when possible. |

### Shared evidence fields

| Field | Required | Notes |
|-------|----------|-------|
| `source_id` | yes | Stable slug or report-local identifier, for example `gsc-2026-05` or `crawl-homepage`. |
| `source_title` | yes | Human-readable source label safe for the report audience. |
| `source_type` | yes | Use the config enum: `first_party`, `third_party`, `benchmark`, `model`, `manual_review`, `generated_artifact`. |
| `observed_date` | yes | ISO date for when the evidence was observed or generated. |
| `claim_supported` | yes | One sentence stating exactly what the evidence supports. |
| `confidence` | yes | `high`, `medium`, or `low`; do not imply certainty from weak sources. |
| `sensitivity` | yes | `public`, `internal`, `confidential`, or `redacted`; redact or aggregate before export when needed. |

## Component Contract

All components share these fields unless explicitly unnecessary: `id`, `component`, `title`, `body`, `evidence`, and `rendering_notes`. Components that create navigation also require `anchor`.

| Component | Required fields | Rendering notes |
|-----------|-----------------|-----------------|
| Cover/meta | `id`, `component`, `title`, `subtitle`, `prepared_for`, `prepared_by`, `prepared_date`, `version`, `confidentiality`, `summary` | First page or report header. Keep sensitive client identifiers controlled by `confidentiality` and `sensitivity`. |
| Sticky TOC | `id`, `component`, `title`, `items[]` with `label`, `anchor`, `level`, `status` | HTML renderers may pin it; Markdown/PDF renderers should degrade to a normal table of contents. |
| Chapter hero heading | `id`, `component`, `title`, `anchor`, `kicker`, `summary`, `priority`, `evidence` | Start major sections with a short outcome-focused summary and optional priority badge. |
| Action line | `id`, `component`, `action`, `owner`, `priority`, `effort`, `impact`, `due`, `evidence` | Use one sentence beginning with a verb. Render as a high-contrast strip or callout. |
| Evidence badge | `id`, `component`, `badge`, `label`, `evidence` | Badge must map to the evidence badge enum. Prefer compact labels with a details link. |
| What/Why/How tactic card | `id`, `component`, `title`, `what`, `why`, `how`, `priority`, `impact`, `effort`, `evidence` | Keep each section scannable. Use for recommendations that need rationale and execution steps. |
| Code/example card | `id`, `component`, `title`, `language`, `code_or_example`, `context`, `copy_safe`, `evidence` | Mark whether content is illustrative or production-ready. Preserve fenced-code readability in Markdown. |
| Good/bad rows | `id`, `component`, `title`, `rows[]` with `good`, `bad`, `reason`, `evidence` | Use for contrastive guidance. Avoid shaming language; focus on observable differences. |
| Stats strip | `id`, `component`, `metrics[]` with `label`, `value`, `unit`, `delta`, `period`, `evidence` | Render as compact KPI cards. Always include period and unit. |
| Facts table | `id`, `component`, `columns[]`, `rows[]`, `evidence` | Use for dense factual data. Keep columns stable across exports. |
| Details note | `id`, `component`, `title`, `body`, `tone`, `evidence` | Render as aside/details block. Use for caveats, assumptions, or implementation notes. |
| Industry card | `id`, `component`, `industry`, `title`, `context`, `pattern`, `implication`, `evidence` | Use when advice differs by vertical. Include the applicability boundary. |
| Priority group | `id`, `component`, `title`, `priority`, `items[]`, `rationale`, `evidence` | Group actions by `critical`, `high`, `medium`, or `low`; sort critical first. |
| Checklist | `id`, `component`, `title`, `items[]` with `label`, `status`, `owner`, `evidence` | Status values: `todo`, `doing`, `done`, `blocked`, `not_applicable`. |
| Source card | `id`, `component`, `source_id`, `source_title`, `source_type`, `observed_date`, `summary`, `sensitivity` | Source cards back citations and should be collected in an appendix or source section. |
| Myth callout | `id`, `component`, `myth`, `reality`, `why_it_matters`, `evidence` | Use sparingly to correct common misconceptions with evidence. |
| Print rules | `id`, `component`, `page_size`, `margins`, `break_rules`, `hide_selectors`, `show_urls`, `footer` | Renderer-only component. Must not carry claims; use to preserve PDF-ready output. |

## Rendering Rules

- Renderers must preserve component order unless a template explicitly defines a safe reordering strategy.
- Missing required fields should fail validation before export, not produce partial reports.
- Evidence badges must link to a source card, footnote, appendix entry, or redacted evidence stub.
- Sensitive fields must be redacted before public export; use `redacted` sensitivity rather than omitting evidence entirely.
- Markdown renderers should remain readable without CSS; HTML renderers may add sticky navigation, cards, and badges; PDF renderers must respect print rules.

## Verification

```bash
python3 -m json.tool .agents/configs/report-component-taxonomy.json.txt >/dev/null
bunx markdownlint-cli2 ".agents/reference/report-component-taxonomy.md" ".agents/reference/domain-index.md"
```
