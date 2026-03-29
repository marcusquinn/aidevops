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

```text
Need data from an authenticated page?
    +-> One-off extraction? --> Curl-Copy (this workflow)
    +-> Repeated/scheduled? --> sweet-cookie + cron
    +-> Need interaction first? --> Playwright or Stagehand
    +-> Bulk pages? --> Crawl4AI with exported cookies
```

<!-- AI-CONTEXT-END -->

## Workflow

### Step 1: Copy the Request from DevTools

1. Open the target page in your browser
2. Open DevTools (`Cmd+Option+I` / `F12`) → **Network** tab
3. Perform the action or reload to capture the request
4. Find the request (filter by `Fetch/XHR` for API calls)
5. Right-click the request → **Copy** → **Copy as cURL** (all browsers support this; Firefox: Copy Value → Copy as cURL)

### Step 2: Use the Copied Command

Paste directly into terminal or AI assistant. The command includes all headers, cookies, and auth tokens from your active session:

```bash
curl 'https://analytics.example.com/api/v1/reports/traffic' \
  -H 'accept: application/json' \
  -H 'authorization: Bearer eyJhbGciOiJSUzI1NiIs...' \
  -H 'cookie: session_id=abc123; csrf_token=xyz789' \
  -H 'user-agent: Mozilla/5.0 ...'
```

### Step 3: Common Modifications

```bash
curl '...' -o output.json                              # Save to file
curl '...' -s | jq .                                   # Pretty-print JSON
curl '...' -L                                          # Follow redirects
curl '...' -X POST -d '{"query": "new data"}'          # Change method
curl '...?page=1&per_page=100' -s | jq .               # Pagination
curl '...' -s | jq '.data[] | {name, value}'           # Extract fields
curl '...' -s -o "export-$(date +%Y%m%d-%H%M%S).json"  # Timestamped save
```

## Practical Examples

### Analytics Dashboard Data

```bash
curl 'https://analytics.example.com/api/reports?range=30d' \
  -H 'cookie: session=...' \
  -s | jq '.rows[] | [.page, .views, .bounceRate] | @csv'
```

### Paginated Admin Panel

```bash
for page in $(seq 1 10); do
  curl "https://admin.example.com/api/users?page=$page&limit=100" \
    -H 'cookie: session=...' \
    -s | jq '.users[]' >> all-users.json
  sleep 1
done
```

### Private API Schema

```bash
curl 'https://app.example.com/api/docs/openapi.json' \
  -H 'cookie: session=...' \
  -s | jq . > api-schema.json
```

### SPA GraphQL Endpoint

```bash
# SPAs use XHR/fetch — filter by Fetch/XHR in DevTools to find API calls
curl 'https://app.example.com/graphql' \
  -H 'content-type: application/json' \
  -H 'cookie: session=...' \
  -d '{"query": "{ users { id name email } }"}' \
  -s | jq .
```

## Tips

**Finding the right request**: Filter by `Fetch/XHR` in DevTools Network tab. Click requests to check Response/Preview tabs for structured JSON data. Use the filter box to search by URL path.

**Session lifetime**: Keep the browser tab open (sessions often auto-refresh). If you get 401/403, re-copy a fresh cURL command. Note which cookie names are session tokens for quick updates.

**Security**:

- Never commit copied cURL commands to git (they contain session tokens)
- Tokens expire in minutes to hours — re-copy as needed
- Add `sleep` between requests to avoid abuse detection
- Strip `cookie`, `authorization`, `x-csrf-token` headers before sharing
- Respect robots.txt even with valid auth

**With AI assistants**: Paste the cURL command with instructions like "run this and extract all product names" or "paginate and compile results as CSV". Note: the command contains your session cookies — only share with trusted assistants.

## Comparison with Other Auth Methods

| Method | Setup | Duration | Automation | Best For |
|--------|-------|----------|------------|----------|
| **Curl-Copy** | Seconds | Min-hours | Manual | One-off extractions |
| **Sweet Cookie** | Minutes | Browser session | Scriptable | Repeated local access |
| **Playwright** | Minutes | Configurable | Full | Automated workflows |
| **Dev-browser** | Minutes | Persistent | Full | Interactive + automation |
| **API keys** | Varies | Long-lived | Full | Official API access |

## Troubleshooting

| Problem | Solution |
|---------|----------|
| 401/403 | Session expired — reload page in browser, re-copy cURL command |
| CORS errors | Not applicable — curl bypasses CORS (browser-only restriction) |
| HTML instead of JSON | Add `-H 'accept: application/json'`, or find the XHR/Fetch request instead of the page URL |
| SSL cert errors | Use `curl '...' -k` for dev servers with self-signed certs |

## Related Tools

- `tools/browser/sweet-cookie.md` - Programmatic cookie extraction from browser databases
- `tools/browser/browser-automation.md` - Full browser automation decision tree
- `tools/browser/dev-browser.md` - Persistent browser profile for automation
- `tools/browser/crawl4ai.md` - Bulk web crawling and extraction
