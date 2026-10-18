# t18716: Add Linkup web search API docs and AI web search API comparison

Issue: GH#34989

## Task

Add Linkup as a documented web search/fetch provider, plus a comparison of AI web search APIs (Linkup, Tavily, Exa, Firecrawl) with routing guidance against existing aidevops options.

## Why

aidevops covers crawlers (Crawl4AI, WaterCrawl, LibreCrawl), browser automation, SERP data (Serper, SerpAPI, DataForSEO), structured data (Outscraper, GetAnyAPI) and AI answers (Perplexity MCP), but has no agent-oriented web search API layer (query -> ranked, cited, LLM-ready content). Linkup (https://www.linkup.so/) fills that gap; Tavily, Exa and Firecrawl are the common alternatives and are not documented as tools.

## How

- New `.agents/tools/research/linkup.md`: endpoints (search, fetch, research, tasks), auth via `aidevops secret set LINKUP_API_KEY`, curl examples, pricing, when to use vs alternatives.
- New `.agents/tools/research/web-search-apis.md`: comparison/decision table for Linkup, Tavily, Exa, Firecrawl versus existing aidevops tools (webfetch, Crawl4AI, browser automation, Serper/SerpAPI, Perplexity).
- Reference pattern: `.agents/tools/data-extraction/getanyapi.md`, `.agents/seo/serper.md`.
- Add routing rows in `.agents/reference/domain-index.md` and an entry in `.agents/aidevops/recommendations.md`.

## Files to modify

### Files Scope

- `.agents/tools/research/linkup.md`
- `.agents/tools/research/web-search-apis.md`
- `.agents/reference/domain-index.md`
- `.agents/aidevops/recommendations.md`
- `.agents/aidevops/onboarding.md`
- `.agents/subagent-index.toon`
- `.agents/configs/allowed-urls.txt`

## Acceptance

- Linkup doc states endpoints, auth, pricing and verified API parameters from Linkup's docs.
- Comparison doc gives a clear decision rule for which tool to use.
- domain-index and recommendations route web search API queries to the new docs.
- `.agents/scripts/linters-local.sh` (markdown checks) pass for changed files.

## Verification

- `markdownlint-cli2` on changed files; `rg -n "linkup" .agents/reference/domain-index.md .agents/aidevops/recommendations.md`.
