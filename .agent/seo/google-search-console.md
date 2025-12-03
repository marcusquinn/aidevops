# Google Search Console MCP Usage Examples

<!-- AI-CONTEXT-START -->

## Quick Reference

- **MCP Integration**: Google Search Console API for AI assistants
- **Setup**: Create Google Cloud Project → Enable Search Console API → Service Account → JSON key
- **Env Vars**: `GOOGLE_APPLICATION_CREDENTIALS="/path/to/key.json"`, `GSC_SITE_URL="https://site.com"`
- **Capabilities**: Search analytics, keyword tracking, device/geographic performance, index coverage
- **Key Methods**: `getSearchAnalytics()`, `getTopPages()`, `getTopQueries()`, `getCoreWebVitals()`
- **Metrics**: clicks, impressions, ctr, position
- **Dimensions**: query, page, country, device, searchAppearance
- **Use Cases**: CTR optimization, position tracking, security/manual action monitoring
<!-- AI-CONTEXT-END -->

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

## Setup Requirements

### **Google Cloud Console Setup**

1. Create a Google Cloud Project
2. Enable the Search Console API
3. Create a Service Account
4. Download the JSON key file
5. Set `GOOGLE_APPLICATION_CREDENTIALS` environment variable

### **Search Console Property Verification**

1. Verify your website in Google Search Console
2. Grant access to your service account email
3. Ensure proper permissions for data access

### **Environment Configuration**

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
export GSC_SITE_URL="https://your-website.com"
```
