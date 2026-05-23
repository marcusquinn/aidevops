<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AEO and GEO Content Patterns

Reference corpus for answer engines, AI Overviews, voice search, and AI citation.

## Chapters

| File | Focus |
|------|-------|
| [`aeo-geo-patterns/01-aeo-patterns.md`](aeo-geo-patterns/01-aeo-patterns.md) | Featured snippets, answer boxes, listicles, FAQs, and voice-search blocks |
| [`aeo-geo-patterns/02-geo-patterns.md`](aeo-geo-patterns/02-geo-patterns.md) | Citation templates, evidence structures, and product-answer patterns for AI assistants |
| [`aeo-geo-patterns/03-authority-signals-and-attribution.md`](aeo-geo-patterns/03-authority-signals-and-attribution.md) | Domain trust signals and UTM citation attribution rules |
| [`aeo-geo-patterns/04-page-type-tactic-matrix.md`](aeo-geo-patterns/04-page-type-tactic-matrix.md) | Page-type weighting for PDP, category, homepage, article, local, SaaS, pricing, comparison, glossary, use-case, and research/report pages |

## How to Use

- Start with the chapter matching the output format you need.
- Use the page-type matrix before recommending tactics; it devalues
  `FAQPage` and other schema work to hygiene unless visible content already
  satisfies the page intent.
- Copy templates verbatim, then replace placeholders with topic-specific facts.
- Keep cited claims, URLs, and freshness details in the chapter files; this index stays slim by design.

## Report-Ready Outputs

- Score material AI-search recommendations with `../ai-search-scoring.md`.
- Convert audit findings into client or worker handoff format with
  `../ai-search-report-template.md`.

## Preservation Notes

- This file is now an index; all original templates and guidance moved into chapter files.
- Content was restructured, not compressed, per `tools/code-review/code-simplifier.md` guidance for reference corpora.
