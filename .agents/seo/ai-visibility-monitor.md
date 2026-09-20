<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# AI Visibility Monitor

Use this leaf to code dated, approved AI-answer captures. It is an offline
measurement tool, not a scraper, provider client, crawler, or factual verifier.

## Collection boundary

- Use only an approved read-only provider or browser route after its readiness and
  authority checks. Keep API and consumer-UI observations on separate engine/mode
  lines; never use a normal signed-in profile or arbitrary endpoint.
- When a route is unsupported, import supplied captures and record `unavailable`.
  Failed or unavailable collection is not a negative answer and never enters a
  valid-answer denominator. No account creation, subscriptions, scheduled crawling
  or live calls are supported by this helper.
- Preserve exact prompt, cohort, engine/product/model (or `unknown`), mode,
  locale/language, timestamp, session context, outcome status and raw source ID.

## Offline workflow

```bash
python3 .agents/scripts/ai-visibility-helper.py import --input captures.json --dry-run
python3 .agents/scripts/ai-visibility-helper.py analyze --input captures.json --decisions brands.json --dry-run
```

`brands.json` contains a small, commercially relevant `brands` list. The report
keeps mention, recommendation, citation and sentiment distinct; citations show
visible source selection only and do not verify claims or prove endorsement.

## Reporting

Read `.agents/seo/ai-search-scoring.md` and
`.agents/seo/seo-geo-experiment-design.md` before interpreting results. Show each
engine/mode/cohort component table before any aggregate, including captures, valid
answers, failed/unavailable counts, completion coverage, observed brands,
recommendations, citations and source types. Repeats are not independent users;
compare controlled cohorts and report variation rather than causality or hidden
retrieval visibility.
