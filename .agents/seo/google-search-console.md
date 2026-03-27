---
description: Google Search Console via MCP (gsc_* tools) with curl fallback
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

# Google Search Console Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Primary access**: MCP tools (`gsc_*`) - enabled for SEO agent
- **Fallback**: curl with OAuth2 token from service account
- **API**: REST at `https://searchconsole.googleapis.com/v1/`
- **Auth**: Service account JSON at `~/.config/aidevops/gsc-credentials.json`
- **Capabilities**: Search analytics, URL inspection, indexing requests, sitemap management
- **Metrics**: clicks, impressions, ctr, position
- **Dimensions**: query, page, country, device, searchAppearance

## Setup

### 1. Google Cloud Project

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Create or select a project
3. Enable the **Google Search Console API**
4. Go to **Credentials** → **Create Credentials** → **Service Account**
5. Name it (e.g., `aidevops`) and create
6. Go to **Keys** tab → **Add Key** → **Create new key** → **JSON**
7. Save to `~/.config/aidevops/gsc-credentials.json` and `chmod 600` it

### 2. Add Service Account to GSC Properties

The service account email (e.g., `aidevops@project-id.iam.gserviceaccount.com`) must be added as a user to each GSC property.

**Manual**: GSC → Property → Settings → Users and permissions → Add user

**Automated**: Use the Playwright script below to bulk-add to all properties.

### 3. Verify Access

```bash
python3 -c "import json; d=json.load(open('$HOME/.config/aidevops/gsc-credentials.json')); print(f'Service account: {d[\"client_email\"]}')"
```

## Direct API Access (curl fallback)

When the MCP is unavailable, use curl with OAuth2 token exchange:

```bash
# Get OAuth2 access token from service account
ACCESS_TOKEN=$(python3 -c "
import json, time, jwt, requests
creds = json.load(open('$HOME/.config/aidevops/gsc-credentials.json'))
now = int(time.time())
payload = {'iss': creds['client_email'], 'scope': 'https://www.googleapis.com/auth/webmasters.readonly',
           'aud': creds['token_uri'], 'iat': now, 'exp': now + 3600}
signed = jwt.encode(payload, creds['private_key'], algorithm='RS256')
r = requests.post(creds['token_uri'], data={'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion': signed})
print(r.json()['access_token'])
")

# List sites
curl -s "https://searchconsole.googleapis.com/v1/sites" \
  -H "Authorization: Bearer $ACCESS_TOKEN"

# Search analytics query
curl -s -X POST "https://searchconsole.googleapis.com/v1/sites/https%3A%2F%2Fexample.com/searchAnalytics/query" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "startDate": "2025-01-01",
    "endDate": "2025-01-20",
    "dimensions": ["query", "page"],
    "rowLimit": 25
  }'

# Submit URL for indexing
curl -s -X POST "https://searchconsole.googleapis.com/v1/urlInspection/index:inspect" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"inspectionUrl": "https://example.com/page", "siteUrl": "https://example.com"}'
```

**Requirements for curl fallback**: `pip install PyJWT requests`

<!-- AI-CONTEXT-END -->

## MCP Tool Reference (`gsc_*`)

The MCP exposes `gsc_*` tools. Key operations:

| Tool | Purpose | Key params |
|------|---------|------------|
| `gsc_list_sites` | List all verified properties | — |
| `gsc_search_analytics` | Query search performance | `siteUrl`, `startDate`, `endDate`, `dimensions[]`, `rowLimit` |
| `gsc_url_inspection` | Inspect URL indexing status | `inspectionUrl`, `siteUrl` |
| `gsc_submit_sitemap` | Submit sitemap | `siteUrl`, `feedpath` |
| `gsc_delete_sitemap` | Remove sitemap | `siteUrl`, `feedpath` |
| `gsc_list_sitemaps` | List submitted sitemaps | `siteUrl` |

**Dimensions**: `query`, `page`, `country`, `device`, `searchAppearance`

**Metrics returned**: `clicks`, `impressions`, `ctr`, `position`

**Common analysis patterns**:
- Top queries by impressions: `dimensions: ["query"]`, `orderBy: impressions`
- Page performance: `dimensions: ["page"]`, `orderBy: clicks`
- Device breakdown: `dimensions: ["device"]`
- Geographic: `dimensions: ["country"]`
- CTR opportunities: filter `impressions > 100` and `ctr < 0.05`

## Automated Bulk Setup with Playwright

Add the service account to all GSC properties automatically:

```javascript
// Save as gsc-add-service-account.js
import { chromium } from 'playwright';

const SERVICE_ACCOUNT = "your-service-account@project.iam.gserviceaccount.com";

async function main() {
    const browser = await chromium.launchPersistentContext(
        '/Users/USERNAME/Library/Application Support/Google/Chrome/Default',
        { headless: false, channel: 'chrome' }
    );

    const page = await browser.newPage();
    await page.goto("https://search.google.com/search-console", { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);

    const html = await page.content();
    const domainRegex = /sc-domain:([a-z0-9.-]+)/g;
    const domains = [...new Set([...html.matchAll(domainRegex)].map(m => m[1]))];
    console.log(`Found ${domains.length} properties`);

    for (const domain of domains) {
        console.log(`Processing ${domain}...`);
        try {
            await page.goto(`https://search.google.com/search-console/users?resource_id=sc-domain:${domain}`,
                { waitUntil: 'networkidle' });
            await page.waitForTimeout(400);

            const content = await page.content();
            if (content.includes("don't have access")) { console.log(`  No access`); continue; }
            if (content.includes(SERVICE_ACCOUNT)) { console.log(`  Already added`); continue; }

            await page.click('text=ADD USER');
            await page.waitForTimeout(400);
            await page.keyboard.type(SERVICE_ACCOUNT, { delay: 5 });
            await page.keyboard.press('Enter');
            await page.waitForTimeout(1000);
            console.log(`  Added`);
        } catch (error) {
            console.error(`  Error: ${error.message}`);
        }
    }
    await browser.close();
}

main().catch(console.error);
```

Run with: `node gsc-add-service-account.js`

**Requirements**: `npm install playwright` · Chrome with logged-in Google session · Owner access to GSC properties

## Troubleshooting

**Empty results `{}`**: Service account not added to any GSC properties — use the Playwright script above.

**"No access to property"**: Service account email must be added as a user (Full or Owner permission). Domain must be verified in GSC first.

**Connection issues**:

```bash
# Check credentials file exists and has correct permissions
ls -la ~/.config/aidevops/gsc-credentials.json

# Test MCP connection
opencode mcp list
```

**Chrome profile paths** (for Playwright):
- macOS: `/Users/USERNAME/Library/Application Support/Google/Chrome/Default`
- Linux: `~/.config/google-chrome/Default`
- Windows: `%LOCALAPPDATA%\Google\Chrome\User Data\Default`

## MCP Configuration

Add to your MCP config (`~/.config/opencode/mcp.json` or similar):

```json
{
  "mcpServers": {
    "google-search-console": {
      "command": "npx",
      "args": ["-y", "@anthropic/google-search-console-mcp"],
      "env": {
        "GOOGLE_APPLICATION_CREDENTIALS": "~/.config/aidevops/gsc-credentials.json"
      }
    }
  }
}
```
