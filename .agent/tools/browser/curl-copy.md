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

**When to Use Curl-Copy**:

- Quick one-off data extraction from authenticated pages
- Scraping behind login walls without setting up automation
- Accessing private/internal APIs discovered in DevTools
- Extracting data from dashboards (analytics, admin panels, CRMs)
- Debugging API responses with real session state

**When NOT to Use**:

- Repeated/scheduled scraping (tokens expire) - use sweet-cookie or Playwright persistent sessions
- Multi-page crawling - use Crawl4AI or Playwright
- Sites requiring interaction (clicks, form fills) - use Stagehand or Playwright
- Long-running sessions (cookies expire in minutes to hours depending on site)

**Quick Decision**:

```text
Need data from an authenticated page?
    |
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
3. Go to the **Network** tab
4. Perform the action or reload the page to capture the request
5. Find the request you want (click on it to inspect headers/response)
6. Right-click the request → **Copy** → **Copy as cURL**

**Browser-specific paths**:

| Browser | Menu Path |
|---------|-----------|
| Chrome | Right-click request → Copy → Copy as cURL (bash) |
| Firefox | Right-click request → Copy Value → Copy as cURL |
| Edge | Right-click request → Copy → Copy as cURL (bash) |
| Safari | Right-click request → Copy as cURL |

### Step 2: Use the Copied cURL Command

Paste the copied command directly into your terminal or AI assistant. The command includes all headers, cookies, and authentication tokens from your active session.

**Example copied command** (headers truncated for brevity):

```bash
curl 'https://analytics.example.com/api/v1/reports/traffic' \
  -H 'accept: application/json' \
  -H 'authorization: Bearer eyJhbGciOiJSUzI1NiIs...' \
  -H 'cookie: session_id=abc123; csrf_token=xyz789; _ga=GA1.2.123456' \
  -H 'referer: https://analytics.example.com/dashboard' \
  -H 'user-agent: Mozilla/5.0 ...'
```

### Step 3: Modify for Your Needs

Common modifications to the copied command:

```bash
# Save output to file
curl '...' -o output.json

# Pretty-print JSON response
curl '...' -s | jq .

# Follow redirects
curl '...' -L

# Change request method
curl '...' -X POST -d '{"query": "new data"}'

# Add pagination
curl '...?page=1&per_page=100' -s | jq .
curl '...?page=2&per_page=100' -s | jq .

# Extract specific fields
curl '...' -s | jq '.data[] | {name: .name, value: .value}'

# Save with timestamp
curl '...' -s -o "export-$(date +%Y%m%d-%H%M%S).json"
```

## Practical Examples

### Extract Analytics Dashboard Data

```bash
# 1. Navigate to analytics dashboard in browser
# 2. Open DevTools Network tab
# 3. Copy the API request that loads the chart/table data
# 4. Paste and pipe through jq

curl 'https://analytics.example.com/api/reports?range=30d' \
  -H 'cookie: session=...' \
  -s | jq '.rows[] | [.page, .views, .bounceRate] | @csv'
```

### Scrape Admin Panel Listings

```bash
# Paginate through all results
for page in $(seq 1 10); do
  curl "https://admin.example.com/api/users?page=$page&limit=100" \
    -H 'cookie: session=...' \
    -s | jq '.users[]' >> all-users.json
  sleep 1  # Be respectful
done
```

### Download Private API Schema

```bash
# Many apps expose OpenAPI/Swagger docs behind auth
curl 'https://app.example.com/api/docs/openapi.json' \
  -H 'cookie: session=...' \
  -s | jq . > api-schema.json
```

### Extract Data from SPA (Single Page App)

```bash
# SPAs often use XHR/fetch calls - look for these in Network tab
# Filter by "Fetch/XHR" in DevTools to find the API calls
# The actual data endpoints are often cleaner than scraping HTML

curl 'https://app.example.com/graphql' \
  -H 'content-type: application/json' \
  -H 'cookie: session=...' \
  -d '{"query": "{ users { id name email } }"}' \
  -s | jq .
```

## Tips

### Finding the Right Request

- **Filter by type**: In DevTools Network tab, filter by `Fetch/XHR` to see API calls (skip images, CSS, JS)
- **Look for JSON responses**: Click requests and check the Response tab - API endpoints return structured data
- **Check the Preview tab**: Chrome shows formatted JSON, making it easy to identify data-rich endpoints
- **Search in Network tab**: Use the filter box to search by URL path or response content

### Extending Session Lifetime

- **Keep the browser tab open**: Some sessions refresh automatically while the tab is active
- **Re-copy when expired**: If you get a 401/403, go back to the browser and copy a fresh cURL command
- **Note the cookie names**: Identify which cookies are session tokens so you know what to update

### Security Considerations

- **Never commit** copied cURL commands to git (they contain session tokens)
- **Tokens expire**: Session cookies and Bearer tokens have limited lifetimes (minutes to hours)
- **Rate limit yourself**: Add `sleep` between requests to avoid triggering abuse detection
- **Respect robots.txt**: Even with valid auth, follow the site's scraping policies
- **Strip sensitive headers** before sharing: Remove `cookie`, `authorization`, and `x-csrf-token` headers

### Working with AI Assistants

The curl-copy workflow pairs well with AI assistants:

1. Copy the cURL command from DevTools
2. Paste it to your AI assistant with instructions like:
   - "Run this and extract all product names and prices"
   - "Paginate through this API and compile the results"
   - "Parse this response and create a CSV"
3. The AI can execute the curl, parse the JSON, and transform the data

**Privacy note**: The pasted cURL command contains your session cookies. Only share with trusted AI assistants running locally or with appropriate data handling policies.

## Comparison with Other Auth Methods

| Method | Setup Time | Session Duration | Automation | Best For |
|--------|-----------|-----------------|------------|----------|
| **Curl-Copy** | Seconds | Minutes-hours | Manual | One-off extractions |
| **Sweet Cookie** | Minutes | Browser session | Scriptable | Repeated local access |
| **Playwright persistent** | Minutes | Configurable | Full | Automated workflows |
| **Dev-browser** | Minutes | Persistent profile | Full | Interactive + automation |
| **API keys** | Varies | Long-lived | Full | Official API access |

## Troubleshooting

### 401 Unauthorized / 403 Forbidden

Session expired. Go back to the browser, reload the page, and copy a fresh cURL command.

### CORS Errors

Not applicable - curl bypasses CORS entirely (CORS is browser-only). If you see CORS-related headers in the response, they can be ignored.

### Empty or HTML Response Instead of JSON

The endpoint may require specific `Accept` headers. Add:

```bash
curl '...' -H 'accept: application/json'
```

Or the URL may be a page URL, not an API URL. Look for XHR/Fetch requests in DevTools instead.

### SSL Certificate Errors

For internal/dev servers with self-signed certs:

```bash
curl '...' -k  # Skip certificate verification (dev only)
```

## Related Tools

- `tools/browser/sweet-cookie.md` - Programmatic cookie extraction from browser databases
- `tools/browser/browser-automation.md` - Full browser automation decision tree
- `tools/browser/dev-browser.md` - Persistent browser profile for automation
- `tools/browser/crawl4ai.md` - Bulk web crawling and extraction
