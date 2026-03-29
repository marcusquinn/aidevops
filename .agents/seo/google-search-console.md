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

- **Primary access**: MCP tools (`gsc_*`) — enabled for SEO agent
- **Fallback**: curl with OAuth2 token from service account
- **API**: REST at `https://searchconsole.googleapis.com/v1/`
- **Auth**: Service account JSON at `~/.config/aidevops/gsc-credentials.json`
- **Capabilities**: Search analytics, URL inspection, indexing requests, sitemap management
- **Metrics**: clicks, impressions, ctr, position
- **Dimensions**: query, page, country, device, searchAppearance

## Setup

1. Google Cloud Console → enable **Google Search Console API** → Credentials → Service Account → JSON key → save to `~/.config/aidevops/gsc-credentials.json` and `chmod 600` it
2. GSC → Property → Settings → Users and permissions → Add user (service account email). For bulk-add across all properties, use the Playwright script below.
3. Verify: `python3 -c "import json; d=json.load(open('$HOME/.config/aidevops/gsc-credentials.json')); print(d['client_email'])"`

## Direct API Access (curl fallback)

**Requirements**: `pip install PyJWT requests`

```bash
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
curl -s "https://searchconsole.googleapis.com/v1/sites" -H "Authorization: Bearer $ACCESS_TOKEN"

# Search analytics query
curl -s -X POST "https://searchconsole.googleapis.com/v1/sites/https%3A%2F%2Fexample.com/searchAnalytics/query" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -d '{"startDate": "2025-01-01", "endDate": "2025-01-20", "dimensions": ["query", "page"], "rowLimit": 25}'

# Inspect URL indexing status (to submit for indexing use indexing.googleapis.com/v3/urlNotifications:publish)
curl -s -X POST "https://searchconsole.googleapis.com/v1/urlInspection/index:inspect" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -d '{"inspectionUrl": "https://example.com/page", "siteUrl": "https://example.com"}'
```

<!-- AI-CONTEXT-END -->

## MCP Tool Reference (`gsc_*`)

| Tool | Purpose | Key params |
|------|---------|------------|
| `gsc_list_sites` | List all verified properties | — |
| `gsc_search_analytics` | Query search performance | `siteUrl`, `startDate`, `endDate`, `dimensions[]`, `rowLimit` |
| `gsc_url_inspection` | Inspect URL indexing status | `inspectionUrl`, `siteUrl` |
| `gsc_submit_sitemap` | Submit sitemap | `siteUrl`, `feedpath` |
| `gsc_delete_sitemap` | Remove sitemap | `siteUrl`, `feedpath` |
| `gsc_list_sitemaps` | List submitted sitemaps | `siteUrl` |

**Common analysis patterns**:
- Top queries by impressions: `dimensions: ["query"]`, `orderBy: impressions`
- Page performance: `dimensions: ["page"]`, `orderBy: clicks`
- Device breakdown: `dimensions: ["device"]`
- Geographic: `dimensions: ["country"]`
- CTR opportunities: filter `impressions > 100` and `ctr < 0.05`

## Bulk Setup with Playwright

Save as `gsc-add-service-account.js`, run with `node gsc-add-service-account.js`. Requires `npm install playwright`, Chrome logged into Google, Owner access to GSC properties.

```javascript
import { chromium } from 'playwright';
const SERVICE_ACCOUNT = "your-service-account@project.iam.gserviceaccount.com";
// Chrome profile: macOS ~/Library/Application Support/Google/Chrome/Default
//                 Linux ~/.config/google-chrome/Default

async function main() {
    const browser = await chromium.launchPersistentContext(
        '/Users/USERNAME/Library/Application Support/Google/Chrome/Default',
        { headless: false, channel: 'chrome' }
    );
    const page = await browser.newPage();
    await page.goto("https://search.google.com/search-console", { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);
    const domains = [...new Set([...((await page.content()).matchAll(/sc-domain:([a-z0-9.-]+)/g))].map(m => m[1]))];
    console.log(`Found ${domains.length} properties`);
    for (const domain of domains) {
        try {
            await page.goto(`https://search.google.com/search-console/users?resource_id=sc-domain:${domain}`, { waitUntil: 'networkidle' });
            await page.waitForTimeout(400);
            const content = await page.content();
            if (content.includes("don't have access") || content.includes(SERVICE_ACCOUNT)) continue;
            await page.click('text=ADD USER');
            await page.waitForTimeout(400);
            await page.keyboard.type(SERVICE_ACCOUNT, { delay: 5 });
            await page.keyboard.press('Enter');
            await page.waitForTimeout(1000);
            console.log(`  Added ${domain}`);
        } catch (e) { console.error(`  Error ${domain}: ${e.message}`); }
    }
    await browser.close();
}
main().catch(console.error);
```

## Troubleshooting

**Empty results `{}`**: Service account not added to any GSC properties — use the Playwright script above.

**"No access to property"**: Service account email must be added as a user (Full or Owner permission). Domain must be verified in GSC first.

**Connection issues**: `ls -la ~/.config/aidevops/gsc-credentials.json` · `opencode mcp list`

## MCP Configuration

> **Note**: `@anthropic/google-search-console-mcp` is an internal/unreleased package. If unavailable via npm, use the curl fallback above or check with your aidevops maintainer for the current install path.

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
