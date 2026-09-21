<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# Google-ranked Reddit opportunities

`prospecting-seo-helper.py refresh --input FILE --dry-run` converts approved
Google SERP captures into an offline, evidence-linked Reddit opportunity view.
Each observation keeps its query, timestamp, provider, locale, language, device,
depth, ordinal, original URL and canonical Reddit URL. `site:reddit.com` output is
discovery-only, never reported as an organic Google rank.

Failed captures and incomplete result depth remain explicit uncertainty; they do
not become deindexing or rank-loss claims. Old, locked, or archived discussions
remain visible when ranked. Thread enrichment is read-only and does not authorize
posting, scraping, account changes, AI-citation claims, or ROI claims.
