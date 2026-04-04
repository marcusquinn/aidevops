---
description: Authenticated scraping via browser DevTools "Copy as cURL" workflow
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Curl-Copy - Authenticated Scraping Workflow

<!-- AI-CONTEXT-START -->

- **Purpose**: Extract data from authenticated pages using the browser's live session cookies
- **Setup**: Browser DevTools + `curl` (built into macOS/Linux)
- **Best for**: Dashboards, gated content, private APIs, admin panels, one-off debugging
- **Use when**: one-off extraction from an authenticated page or internal API
- **Don't use when**: repeated jobs → `sweet-cookie`; interaction required → Playwright/Stagehand; bulk crawling → Crawl4AI

```text
Need data from an authenticated page?
    +-> One-off extraction? --> Curl-Copy
    +-> Repeated/scheduled? --> sweet-cookie + cron
    +-> Need interaction first? --> Playwright or Stagehand
    +-> Bulk pages? --> Crawl4AI with exported cookies
```

<!-- AI-CONTEXT-END -->

## Workflow

1. Open the target page; open DevTools (`Cmd+Option+I` / `F12`).
2. In **Network**, filter to `Fetch/XHR`; reload or repeat the action.
3. Right-click the request → **Copy** → **Copy as cURL**:
   - Chrome/Edge: `Copy as cURL (bash)`
   - Firefox: `Copy Value → Copy as cURL`
   - Safari: `Copy as cURL`
4. Paste into a terminal or local AI assistant — the command already contains active headers, cookies, and auth state.

```bash
# Example copied command (headers truncated)
curl 'https://analytics.example.com/api/v1/reports/traffic' \
  -H 'accept: application/json' \
  -H 'authorization: Bearer eyJhbGciOiJSUzI1NiIs...' \
  -H 'cookie: session_id=abc123; csrf_token=xyz789' \
  -H 'user-agent: Mozilla/5.0 ...'

# Common transforms
curl '...' -o output.json                                    # save raw output
curl '...' -s | jq .                                         # pretty-print JSON
curl '...' -L                                                # follow redirects
curl '...' -X POST -d '{"query": "new data"}'                # modify method/body
curl '...' -s | jq '.data[] | {name: .name, value: .value}'  # extract fields
curl '...' -s -o "export-$(date +%Y%m%d-%H%M%S).json"        # timestamped export
curl '...?page=1&per_page=100' -s | jq .                     # test pagination
```

## Practical Patterns

```bash
# Analytics/dashboard extraction
curl 'https://analytics.example.com/api/reports?range=30d' \
  -H 'cookie: session=...' \
  -s | jq '.rows[] | [.page, .views, .bounceRate] | @csv'

# Paginate admin panel listings
for page in $(seq 1 10); do
  curl "https://admin.example.com/api/users?page=$page&limit=100" \
    -H 'cookie: session=...' \
    -s | jq '.users[]' >> all-users.json
  sleep 1
done

# Download private OpenAPI/Swagger schema behind auth
curl 'https://app.example.com/api/docs/openapi.json' \
  -H 'cookie: session=...' -s | jq . > api-schema.json

# GraphQL request copied from a SPA
curl 'https://app.example.com/graphql' \
  -H 'content-type: application/json' -H 'cookie: session=...' \
  -d '{"query": "{ users { id name email } }"}' -s | jq .
```

## Operating Notes

| Topic | Guidance |
|-------|----------|
| Find the right request | Stay in `Fetch/XHR`, inspect **Response/Preview**, search by URL path |
| Session lifetime | Keep the tab open if possible; copy a fresh command after `401/403` |
| Sharing safely | Strip `cookie`, `authorization`, and `x-csrf-token` before sharing |
| Responsible use | Add `sleep` between requests, respect robots.txt, avoid abuse detection |
| AI assistants | Safe only with trusted local assistants; copied commands contain live session tokens |

## Method Comparison

| Method | Setup | Session duration | Automation | Best for |
|--------|-------|------------------|------------|----------|
| **Curl-Copy** | Seconds | Minutes-hours | Manual | One-off extractions |
| **Sweet Cookie** | Minutes | Browser session | Scriptable | Repeated local access |
| **Playwright persistent** | Minutes | Configurable | Full | Automated workflows |
| **Dev-browser** | Minutes | Persistent profile | Full | Interactive + automation |
| **API keys** | Varies | Long-lived | Full | Official API access |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `401/403` | Session expired; reload the page and copy a fresh cURL command |
| CORS errors | Not applicable; `curl` bypasses browser CORS restrictions |
| HTML/empty response instead of JSON | Add `-H 'accept: application/json'`, or copy the XHR/Fetch request instead of the page URL |
| SSL certificate errors | For internal/dev servers with self-signed certs, add `-k` temporarily |

## Related

- `tools/browser/sweet-cookie.md` - Reuse browser cookies programmatically
- `tools/browser/browser-automation.md` - Browser tool selection guide
- `tools/browser/dev-browser.md` - Persistent browser profile automation
- `tools/browser/crawl4ai.md` - Bulk crawling and extraction
