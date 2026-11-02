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

Geogrid alternative (third in order, after SEO Utils and `seo/dataforseo.md`
"Local pack / Maps grid collection"): run `engine=google_maps` with
`type=search`, `q=<keyword>` and `ll=@<lat>,<lng>,<zoom>z` (for example
`@40.7455096,-74.0083012,14z`; `map_height` in metres also works) once per grid
point, keeping `hl`, `google_domain` and the cutoff constant. Hold the provider's
device context constant across all points and record it as `device` in scan
metadata; verify the Maps engine's current device support before attempting an
override rather than assuming Google Search's device options apply. Read the
business's `position` in `local_results` by `place_id`. Results are not
guaranteed to lie inside the requested area. Each search counts against the
plan, and identical searches within 1h may be served free from cache (`no_cache`
forces a fresh, billable fetch), so estimate points × keywords before running
and ask first. Metrics and guardrails: `seo/seo-utils.md` "Geogrid metrics".

<!-- AI-CONTEXT-END -->
