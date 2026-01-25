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

## Setup Steps

### 1. Google Cloud Project Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Create or select a project
3. Enable the **Google Search Console API**
4. Go to **Credentials** → **Create Credentials** → **Service Account**
5. Name it (e.g., `aidevops`) and create
6. Go to **Keys** tab → **Add Key** → **Create new key** → **JSON**
7. Save the downloaded file to `~/.config/aidevops/gsc-credentials.json`
8. Set permissions: `chmod 600 ~/.config/aidevops/gsc-credentials.json`

### 2. Add Service Account to GSC Properties

The service account email (e.g., `aidevops@project-id.iam.gserviceaccount.com`) must be added as a user to each GSC property.

**Manual method**: GSC → Property → Settings → Users and permissions → Add user

**Automated method**: Use Playwright to bulk-add to all properties (see below)

### 3. Verify Access

```bash
# Verify credentials file
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

## Automated Bulk Setup with Playwright

Add the service account to all GSC properties automatically:

```javascript
// Save as gsc-add-service-account.js
import { chromium } from 'playwright';

const SERVICE_ACCOUNT = "your-service-account@project.iam.gserviceaccount.com";

async function main() {
    // Launch Chrome with user profile (logged into Google)
    const browser = await chromium.launchPersistentContext(
        '/Users/USERNAME/Library/Application Support/Google/Chrome/Default',
        { headless: false, channel: 'chrome' }
    );
    
    const page = await browser.newPage();
    await page.goto("https://search.google.com/search-console", { waitUntil: 'networkidle' });
    await page.waitForTimeout(2000);
    
    // Get all domains from the page
    const html = await page.content();
    const domainRegex = /sc-domain:([a-z0-9.-]+)/g;
    const matches = [...html.matchAll(domainRegex)];
    const domains = [...new Set(matches.map(m => m[1]))];
    
    console.log(`Found ${domains.length} properties`);
    
    for (const domain of domains) {
        console.log(`Processing ${domain}...`);
        
        try {
            await page.goto(`https://search.google.com/search-console/users?resource_id=sc-domain:${domain}`, 
                { waitUntil: 'networkidle' });
            await page.waitForTimeout(400);
            
            const content = await page.content();
            
            // Skip if no access or already added
            if (content.includes("don't have access")) {
                console.log(`  ⏭ No access`);
                continue;
            }
            if (content.includes(SERVICE_ACCOUNT)) {
                console.log(`  ⏭ Already added`);
                continue;
            }
            
            // Click ADD USER, type email, press Enter
            await page.click('text=ADD USER');
            await page.waitForTimeout(400);
            await page.keyboard.type(SERVICE_ACCOUNT, { delay: 5 });
            await page.keyboard.press('Enter');
            await page.waitForTimeout(1000);
            
            console.log(`  ✓ Added`);
        } catch (error) {
            console.error(`  ✗ ${error.message}`);
        }
    }
    
    await browser.close();
}

main().catch(console.error);
```

Run with: `node gsc-add-service-account.js`

**Requirements**:
- Playwright installed: `npm install playwright`
- Chrome browser with logged-in Google session
- User must have Owner access to GSC properties

## Search Performance Analysis

### **Query Performance Metrics**

```javascript
// Get search performance data for specific queries
await googleSearchConsole.getSearchAnalytics({
  siteUrl: "https://your-website.com",
  startDate: "2024-01-01",
  endDate: "2024-12-31",
  dimensions: ["query", "page", "country", "device"],
  metrics: ["clicks", "impressions", "ctr", "position"]
});
```

### **Top Performing Pages**

```javascript
// Analyze top performing pages by clicks
await googleSearchConsole.getTopPages({
  siteUrl: "https://your-website.com",
  startDate: "2024-11-01",
  endDate: "2024-11-30",
  orderBy: "clicks",
  limit: 50
});
```

## Keyword Research & Analysis

### **Top Search Queries**

```javascript
// Get top search queries driving traffic
await googleSearchConsole.getTopQueries({
  siteUrl: "https://your-website.com",
  startDate: "2024-10-01",
  endDate: "2024-10-31",
  orderBy: "impressions",
  limit: 100
});
```

### **Query Position Tracking**

```javascript
// Track specific keyword positions over time
await googleSearchConsole.trackKeywordPositions({
  siteUrl: "https://your-website.com",
  queries: ["ai assisted devops", "automation framework", "mcp integration"],
  startDate: "2024-01-01",
  endDate: "2024-12-31",
  groupBy: "month"
});
```

## Device & Geographic Analysis

### **Device Performance Breakdown**

```javascript
// Analyze performance across different devices
await googleSearchConsole.getDevicePerformance({
  siteUrl: "https://your-website.com",
  startDate: "2024-11-01",
  endDate: "2024-11-30",
  devices: ["desktop", "mobile", "tablet"],
  metrics: ["clicks", "impressions", "ctr", "position"]
});
```

### **Geographic Performance**

```javascript
// Get performance data by country
await googleSearchConsole.getGeographicPerformance({
  siteUrl: "https://your-website.com",
  startDate: "2024-11-01",
  endDate: "2024-11-30",
  countries: ["USA", "GBR", "CAN", "AUS"],
  orderBy: "clicks"
});
```

## Technical SEO Monitoring

### **Index Coverage Analysis**

```javascript
// Check index coverage status
await googleSearchConsole.getIndexCoverage({
  siteUrl: "https://your-website.com",
  category: "all", // or "error", "valid", "excluded", "warning"
  platform: "web" // or "mobile"
});
```

### **Core Web Vitals Monitoring**

```javascript
// Monitor Core Web Vitals performance
await googleSearchConsole.getCoreWebVitals({
  siteUrl: "https://your-website.com",
  category: "all", // or "good", "needs_improvement", "poor"
  platform: "desktop" // or "mobile"
});
```

## Competitive Analysis

### **Search Appearance Features**

```javascript
// Analyze search appearance features (rich snippets, etc.)
await googleSearchConsole.getSearchAppearance({
  siteUrl: "https://your-website.com",
  startDate: "2024-11-01",
  endDate: "2024-11-30",
  searchAppearance: ["richSnippet", "ampBlueLink", "ampNonRichResult"]
});
```

### **Click-Through Rate Optimization**

```javascript
// Identify pages with high impressions but low CTR
await googleSearchConsole.getCTROpportunities({
  siteUrl: "https://your-website.com",
  startDate: "2024-11-01",
  endDate: "2024-11-30",
  minImpressions: 100,
  maxCTR: 0.05, // 5% CTR threshold
  orderBy: "impressions"
});
```

## Issue Detection & Monitoring

### **Manual Actions Check**

```javascript
// Check for manual actions against the site
await googleSearchConsole.getManualActions({
  siteUrl: "https://your-website.com"
});
```

### **Security Issues Monitoring**

```javascript
// Monitor security issues
await googleSearchConsole.getSecurityIssues({
  siteUrl: "https://your-website.com"
});
```

## Reporting & Analytics

### **Monthly Performance Report**

```javascript
// Generate comprehensive monthly report
await googleSearchConsole.generateMonthlyReport({
  siteUrl: "https://your-website.com",
  month: "2024-11",
  includeMetrics: ["clicks", "impressions", "ctr", "position"],
  includeDimensions: ["query", "page", "country", "device"],
  exportFormat: "json" // or "csv"
});
```

### **Competitor Comparison**

```javascript
// Compare performance with competitor keywords
await googleSearchConsole.compareWithCompetitors({
  siteUrl: "https://your-website.com",
  competitorQueries: ["devops automation", "infrastructure management"],
  startDate: "2024-11-01",
  endDate: "2024-11-30",
  metrics: ["position", "clicks", "impressions"]
});
```

## Troubleshooting

### Empty Results from API

If the API returns empty results `{}`:
- Service account not added to any GSC properties
- Use the Playwright script above to bulk-add access

### "No access to property" Error

- The service account email must be added as a user (Full or Owner permission)
- Domain must be verified in GSC first

### Connection Issues

```bash
# Check credentials file exists and has correct permissions
ls -la ~/.config/aidevops/gsc-credentials.json

# Verify service account email
cat ~/.config/aidevops/gsc-credentials.json | grep client_email

# Test MCP connection
opencode mcp list
```

### Chrome Profile Path (for Playwright)

- **macOS**: `/Users/USERNAME/Library/Application Support/Google/Chrome/Default`
- **Linux**: `~/.config/google-chrome/Default`
- **Windows**: `%LOCALAPPDATA%\Google\Chrome\User Data\Default`

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
