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

# Curl-Copy - Authenticated Scraping Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract data from authenticated pages using browser session cookies via DevTools "Copy as cURL"
- **No install required**: Uses browser DevTools + curl (built into macOS/Linux)
- **Best for**: Dashboards, gated content, private APIs, admin panels, one-off extractions

**Use when**: One-off extraction from authenticated pages, scraping behind login walls, accessing private/internal APIs from DevTools, extracting dashboard data, debugging API responses with real session state.

**Don't use when**: Repeated/scheduled scraping (tokens expire — use sweet-cookie or Playwright persistent sessions), multi-page crawling (use Crawl4AI or Playwright), interaction required (use Stagehand or Playwright), long-running sessions (cookies expire).

```text
Need data from an authenticated page?
    +-> One-off extraction? --> Curl-Copy (this workflow)
    +-> Repeated/scheduled? --> sweet-cookie + cron
    +-> Need to interact first? --> Playwright or Stagehand
    +-> Bulk pages? --> Crawl4AI with exported cookies
```

<!-- AI-CONTEXT-END -->

## Workflow

### Step 1: Copy the Request from DevTools

1. Open the target page in your browser (Chrome, Firefox, Edge, Safari)
2. Open DevTools: `Cmd+Option+I` (macOS) or `F12` (Windows/Linux)
3. Go to the **Network** tab, filter by `Fetch/XHR` to see API calls
4. Perform the action or reload the page to capture the request
5. Right-click the request → **Copy** → **Copy as cURL** (Chrome/Edge: "Copy as cURL (bash)", Firefox: "Copy Value → Copy as cURL", Safari: "Copy as cURL")

### Step 2: Execute and Transform

Paste the copied command directly into terminal or AI assistant. It includes all headers, cookies, and auth tokens from your active session.

```bash
# Example copied command (headers truncated)
curl 'https://analytics.example.com/api/v1/reports/traffic' \
  -H 'accept: application/json' \
  -H 'authorization: Bearer eyJhbGciOiJSUzI1NiIs...' \
  -H 'cookie: session_id=abc123; csrf_token=xyz789' \
  -H 'user-agent: Mozilla/5.0 ...'

# Common modifications
curl '...' -o output.json                                    # Save to file
curl '...' -s | jq .                                         # Pretty-print JSON
curl '...' -L                                                # Follow redirects
curl '...' -X POST -d '{"query": "new data"}'                # Change method
curl '...' -s | jq '.data[] | {name: .name, value: .value}'  # Extract fields
curl '...' -s -o "export-$(date +%Y%m%d-%H%M%S).json"        # Timestamped save
curl '...?page=1&per_page=100' -s | jq .                     # Pagination
```

## Practical Examples

```bash
# Extract analytics dashboard data — pipe chart/table API through jq
curl 'https://analytics.example.com/api/reports?range=30d' \
  -H 'cookie: session=...' \
  -s | jq '.rows[] | [.page, .views, .bounceRate] | @csv'

# Paginate admin panel listings
for page in $(seq 1 10); do
  curl "https://admin.example.com/api/users?page=$page&limit=100" \
    -H 'cookie: session=...' \
    -s | jq '.users[]' >> all-users.json
  sleep 1  # Be respectful
done

# Download private API schema (OpenAPI/Swagger behind auth)
curl 'https://app.example.com/api/docs/openapi.json' \
  -H 'cookie: session=...' -s | jq . > api-schema.json

# SPA GraphQL — filter by Fetch/XHR in DevTools to find data endpoints
curl 'https://app.example.com/graphql' \
  -H 'content-type: application/json' -H 'cookie: session=...' \
  -d '{"query": "{ users { id name email } }"}' -s | jq .
```

## Tips

**Finding the right request**: Filter by `Fetch/XHR` in DevTools Network tab to skip images/CSS/JS. Click requests and check the Response/Preview tab for structured JSON data. Use the filter box to search by URL path.

**Extending session lifetime**: Keep the browser tab open (some sessions auto-refresh). If you get 401/403, copy a fresh cURL command. Note which cookie names are session tokens for quick updates.

**Security**: Never commit copied cURL commands to git (they contain session tokens). Add `sleep` between requests to avoid abuse detection. Respect robots.txt. Strip `cookie`, `authorization`, and `x-csrf-token` headers before sharing.

**With AI assistants**: Paste the cURL command with instructions like "extract all product names" or "paginate and compile results". The AI executes curl, parses JSON, and transforms data. **Privacy**: the command contains session cookies — only share with trusted, locally-running assistants.

## Auth Method Comparison

| Method | Setup | Session Duration | Automation | Best For |
|--------|-------|-----------------|------------|----------|
| **Curl-Copy** | Seconds | Minutes-hours | Manual | One-off extractions |
| **Sweet Cookie** | Minutes | Browser session | Scriptable | Repeated local access |
| **Playwright persistent** | Minutes | Configurable | Full | Automated workflows |
| **Dev-browser** | Minutes | Persistent profile | Full | Interactive + automation |
| **API keys** | Varies | Long-lived | Full | Official API access |

## Troubleshooting

- **401/403**: Session expired — reload the page in browser and copy a fresh cURL command
- **CORS errors**: Not applicable — curl bypasses CORS entirely (browser-only restriction)
- **Empty/HTML response instead of JSON**: Add `-H 'accept: application/json'`, or the URL may be a page URL not an API endpoint — look for XHR/Fetch requests in DevTools instead
- **SSL certificate errors**: For internal/dev servers with self-signed certs: `curl '...' -k` (dev only)

## Related Tools

- `tools/browser/sweet-cookie.md` - Programmatic cookie extraction from browser databases
- `tools/browser/browser-automation.md` - Full browser automation decision tree
- `tools/browser/dev-browser.md` - Persistent browser profile for automation
- `tools/browser/crawl4ai.md` - Bulk web crawling and extraction
