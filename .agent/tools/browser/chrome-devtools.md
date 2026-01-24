---
description: Chrome DevTools MCP for debugging and inspection
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

# Chrome DevTools MCP - Debugging & Inspection Companion

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Debugging/inspection layer that connects to ANY running Chrome/Chromium instance
- **Not a browser**: Pairs with dev-browser, Playwright, Playwriter, or standalone Chrome
- **Install**: `npx chrome-devtools-mcp@latest`
- **Package**: `chrome-devtools-mcp` (v0.13.0+, maintained by Google)

**Connection methods**:

```bash
# Connect to dev-browser (port 9222)
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222

# Connect via WebSocket
npx chrome-devtools-mcp@latest --wsEndpoint ws://127.0.0.1:9222/devtools/browser/<id>

# Launch its own Chrome (headless)
npx chrome-devtools-mcp@latest --headless

# With isolated profile (temp, auto-cleaned)
npx chrome-devtools-mcp@latest --isolated

# With proxy
npx chrome-devtools-mcp@latest --proxyServer socks5://127.0.0.1:1080

# Use Chrome Beta/Canary/Dev
npx chrome-devtools-mcp@latest --channel canary

# Auto-connect to user's Chrome (Chrome 145+, requires chrome://inspect/#remote-debugging)
npx chrome-devtools-mcp@latest --autoConnect
```

**Capabilities**:
- Performance: `lighthouse()`, `measureWebVitals()` (LCP, FID, CLS, TTFB)
- Network: `monitorNetwork()`, `throttleRequest()` (individual request throttling, Chrome 136+)
- Scraping: `extractData()`, `screenshot()` (fullPage, element)
- Debug: `captureConsole()`, CSS coverage, visual regression
- Mobile: `emulateDevice()`, `simulateTouch()` (tap, swipe)
- SEO: `extractSEO()`, `validateStructuredData()`
- Automation: `comprehensiveAnalysis()`, `comparePages()` (A/B testing)

**Best pairings**:
- **dev-browser + DevTools**: Persistent profile + deep inspection
- **Playwright + DevTools**: Speed + performance profiling
- **Playwriter + DevTools**: Your browser + debugging your extensions

**When to use**: Performance auditing, network debugging, SEO analysis, visual regression testing. Use alongside a browser tool, not instead of one.

**Category toggles** (reduce MCP tool count):

```bash
npx chrome-devtools-mcp@latest --categoryEmulation false --categoryPerformance false
```

<!-- AI-CONTEXT-END -->

## Performance Analysis

### **Lighthouse Performance Audit**

```javascript
// Request a Lighthouse audit for performance optimization
await chromeDevTools.lighthouse({
  url: "https://your-website.com",
  categories: ["performance", "accessibility", "best-practices", "seo"],
  device: "desktop"
});
```

### **Core Web Vitals Monitoring**

```javascript
// Monitor Core Web Vitals in real-time
await chromeDevTools.measureWebVitals({
  url: "https://your-website.com",
  metrics: ["LCP", "FID", "CLS", "TTFB"],
  iterations: 5
});
```

## 🕷️ **Web Scraping & Data Extraction**

### **Extract Page Content**

```javascript
// Extract structured data from a webpage
await chromeDevTools.extractData({
  url: "https://example.com",
  selectors: {
    title: "h1",
    description: ".description",
    links: "a[href]"
  }
});
```

### **Screenshot Generation**

```javascript
// Generate full-page screenshots
await chromeDevTools.screenshot({
  url: "https://your-website.com",
  fullPage: true,
  format: "png",
  quality: 90
});
```

## 🐛 **Debugging & Testing**

### **Console Log Analysis**

```javascript
// Capture and analyze console errors
await chromeDevTools.captureConsole({
  url: "https://your-website.com",
  logLevel: "error",
  duration: 30000
});
```

### **Network Request Monitoring**

```javascript
// Monitor network requests and responses
await chromeDevTools.monitorNetwork({
  url: "https://your-website.com",
  filters: ["xhr", "fetch", "document"],
  captureHeaders: true,
  captureBody: true
});
```

## **Network Conditions & Throttling**

### **Individual Request Throttling** (New in Chrome 136+)

Chrome DevTools now supports throttling individual network requests rather than the entire page. This enables precise testing of how your application handles slow-loading specific resources.

**Use cases:**
- Test lazy-loading behavior when specific images load slowly
- Simulate slow API responses without affecting other requests
- Debug race conditions when certain scripts load out of order
- Test error handling for slow third-party resources

```javascript
// Throttle a specific API endpoint
await chromeDevTools.throttleRequest({
  url: "https://your-website.com",
  requestPattern: "**/api/slow-endpoint",
  latency: 3000,  // Add 3 second delay
  downloadThroughput: 50 * 1024  // 50 KB/s
});

// Throttle specific image requests
await chromeDevTools.throttleRequest({
  url: "https://your-website.com",
  requestPattern: "*.jpg",
  latency: 2000,
  downloadThroughput: 100 * 1024  // 100 KB/s
});

// Throttle multiple patterns with different conditions
await chromeDevTools.throttleRequests({
  url: "https://your-website.com",
  rules: [
    {
      pattern: "**/api/critical",
      latency: 0,
      downloadThroughput: -1  // No throttling (priority)
    },
    {
      pattern: "**/api/*",
      latency: 1500,
      downloadThroughput: 200 * 1024
    },
    {
      pattern: "*.woff2",
      latency: 500,
      downloadThroughput: 50 * 1024
    }
  ]
});
```

**Manual DevTools usage:**
1. Open DevTools (F12) → Network panel
2. Right-click any request → "Throttle request"
3. Choose preset (Slow 3G, Fast 3G) or custom values
4. Request-specific throttling persists until cleared

**Comparison with page-level throttling:**

| Feature | Page-Level | Individual Request |
|---------|------------|-------------------|
| Scope | All requests | Specific URL patterns |
| Use case | General slow network testing | Targeted resource testing |
| Precision | Low | High |
| Real-world simulation | Broad conditions | Specific failure scenarios |

## 📱 **Mobile Testing**

### **Device Emulation**

```javascript
// Test mobile responsiveness
await chromeDevTools.emulateDevice({
  url: "https://your-website.com",
  device: "iPhone 12 Pro",
  orientation: "portrait"
});
```

### **Touch Event Testing**

```javascript
// Simulate touch interactions
await chromeDevTools.simulateTouch({
  url: "https://your-website.com",
  actions: [
    { type: "tap", x: 100, y: 200 },
    { type: "swipe", startX: 100, startY: 300, endX: 300, endY: 300 }
  ]
});
```

## 🔍 **SEO Analysis**

### **Meta Tag Extraction**

```javascript
// Extract SEO-relevant meta tags
await chromeDevTools.extractSEO({
  url: "https://your-website.com",
  elements: ["title", "meta[name='description']", "meta[property^='og:']", "link[rel='canonical']"]
});
```

### **Structured Data Validation**

```javascript
// Validate structured data markup
await chromeDevTools.validateStructuredData({
  url: "https://your-website.com",
  schemas: ["Organization", "WebSite", "Article"]
});
```

## 🚀 **Automation Workflows**

### **Multi-Page Analysis**

```javascript
// Analyze multiple pages in sequence
const urls = [
  "https://your-website.com",
  "https://your-website.com/about",
  "https://your-website.com/contact"
];

for (const url of urls) {
  await chromeDevTools.comprehensiveAnalysis({
    url: url,
    includePerformance: true,
    includeSEO: true,
    includeAccessibility: true
  });
}
```

### **A/B Testing Support**

```javascript
// Compare two versions of a page
await chromeDevTools.comparePages({
  urlA: "https://your-website.com/version-a",
  urlB: "https://your-website.com/version-b",
  metrics: ["performance", "visual-diff", "accessibility"]
});
```

## 🎨 **Visual Testing**

### **Visual Regression Testing**

```javascript
// Capture baseline and compare screenshots
await chromeDevTools.visualRegression({
  url: "https://your-website.com",
  baseline: "/path/to/baseline.png",
  threshold: 0.1,
  highlightDifferences: true
});
```

### **CSS Coverage Analysis**

```javascript
// Analyze unused CSS
await chromeDevTools.analyzeCSSCoverage({
  url: "https://your-website.com",
  reportUnused: true,
  minifyRecommendations: true
});
```
