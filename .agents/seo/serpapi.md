---
description: Google and other search engine results via SerpApi (curl-based, no MCP needed)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# SerpApi - Search Engine Results API

<!-- AI-CONTEXT-START -->

- **API**: `https://serpapi.com/search.json?engine=<engine>`. Engines include `google`, `google_autocomplete`, `google_maps`, `google_news`, `bing`, `duckduckgo` and `youtube`
- **Auth**: `aidevops secret set SERPAPI_API_KEY`, resolved from the environment, `~/.config/aidevops/credentials.sh`, then gopass `aidevops/SERPAPI_API_KEY`
- **Account**: https://serpapi.com/ (sign in → API key, usage, plan)
- **Helper**: `keyword-research-helper.sh autocomplete "<kw>" --provider serpapi`, `keyword-research-helper.sh serp-compare "<kw>"`
- **Role**: alternative to DataForSEO/Serper; use it to cross-check vendor SERP data (`seo/keyword-research.md` "Questionable SERP data")

Keep the API key out of argv and logs. The helper passes it through a curl
config on stdin; reuse `serpapi_request` from
`scripts/keyword-research-helper-providers.sh` rather than putting
`api_key=...` in the URL.

```bash
source ~/.aidevops/agents/scripts/shared-constants.sh
source ~/.aidevops/agents/scripts/keyword-research-helper-providers.sh
serpapi_request google "q=crm software" "gl=uk" "hl=en" | jq '.organic_results[] | {position, link, title}'
serpapi_request google_autocomplete "q=crm for" "gl=us" | jq -r '.suggestions[].value'
serpapi_request bing "q=crm software" "cc=GB" | jq '.organic_results[:5]'
```

Common Google parameters: `q`, `gl` (country), `hl` (language), `location`
(canonical location name), `google_domain`, `device` (`desktop|mobile|tablet`),
`start` (pagination offset). Errors come back as a top-level `error` string;
`search_metadata.status` is `Success` on completion.

<!-- AI-CONTEXT-END -->
