---
description: Direct-source news search and article evidence collection for PR workflows
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# PR News Search

Collect dated, attributed article evidence for PR decisions without relying on proprietary media APIs.

## Required article fields

For every result, capture:

- `title`
- `url` and canonical URL when different
- `outlet`
- `author` or `unknown`
- `published_at` or `unknown`
- `fetched_at`
- `source_type`: editorial, wire/syndication, press release, blog, aggregator, unknown
- `evidence_note`: why this article matters

Never invent missing authors, outlets, or publication dates.

## Source order

1. User-provided URLs and pasted evidence.
2. RSS/Atom feeds from relevant outlets, Google News RSS queries, trade publications, regulator/agency feeds, company newsroom feeds.
3. Runtime search/browser tools using recency-bounded queries.
4. Public corpora/search services only when already configured by the user.

## Extraction checks

- Prefer Schema.org `NewsArticle`, OpenGraph, RSS dates, canonical URL, visible byline/date, and author profile links.
- Mark date confidence: `exact_timestamp`, `date_only`, `visible_but_unstructured`, `unknown`.
- Flag syndication: wire labels, “originally published”, partner networks, PRNewswire/BusinessWire/GlobeNewswire, Yahoo/MSN/AOL pickups.
- Distinguish source-of-record from pickups; do not launder an aggregator into original coverage.

## Output

Return a short evidence table plus caveats:

| Title | Outlet | Author | Published | Type | Relevance | URL |
|---|---|---|---|---|---|---|

When used by another PR workflow, pass the machine-readable fields as JSON/CSV if the runtime can save artifacts.
