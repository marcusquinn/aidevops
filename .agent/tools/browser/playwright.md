---
description: Cross-browser testing automation with Playwright MCP
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

# Playwright MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Cross-browser testing and automation (fastest browser engine)
- **Install**: `npm install playwright && npx playwright install`
- **MCP**: `npx @playwright/mcp` (with `--proxy-server`, `--storage-state` options)
- **Browsers**: chromium, firefox, webkit
- **Headless**: Yes (default)

**Performance** (fastest of all tools): Navigate 1.4s, form fill 0.9s, extraction 1.3s, reliability 0.64s avg.
This is the underlying engine used by dev-browser, agent-browser, and Stagehand.

**Key Features**:
- Full proxy support (HTTP, SOCKS5, per-context)
- Session persistence via `storageState` or `userDataDir`
- Cross-browser testing (Chromium, Firefox, WebKit)
- Device emulation (iPhone, Samsung, iPad)
- Network throttling (Fast 3G, Slow 3G, Offline)
- Browser extensions via `launchPersistentContext` + `--load-extension`
- Parallel: 5 isolated contexts in 2.1s, 3 browsers in 1.9s, 10 pages in 1.8s
- AI page understanding: `page.locator('body').ariaSnapshot()` (~0.01s, 50-200 tokens)
- Integration: Works with Chrome DevTools MCP, dev-browser, Stagehand

**When to use directly**: Maximum speed, full control, proxy support, parallel instances, extensions, or when other wrappers add unnecessary overhead.

**Extensions**: Use `launchPersistentContext` with `--load-extension` arg. Requires bundled Chromium (not Chrome/Brave channel). Password managers load but need manual unlock.

**Chrome DevTools MCP**: Connect via `npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222` for Lighthouse, network monitoring, CSS coverage alongside Playwright automation.

**Test types**:
  - Cross-browser: `runTest()`, `testBrowserFeatures()`
  - User flows: `automateFlow()`, `testFormValidation()`
  - Mobile: `testOnDevice()`, `testOrientations()`
  - Performance: `measurePerformance()`, `testWithNetwork()`
  - Visual: `visualRegressionSuite()`, `screenshotComponents()`
  - Security: `testXSS()`, `testAuthentication()`
  - API: `testAPIIntegration()`, `testRealTimeFeatures()`

<!-- AI-CONTEXT-END -->

## Installation

Playwright MCP is auto-installed via `setup.sh` when running the browser tools setup:

```bash
# Via setup.sh (interactive)
./setup.sh --interactive
# Select: "Setup browser automation tools"

# Manual installation
npx playwright install              # Install browsers (chromium, firefox, webkit)
npx playwright-mcp@latest           # Run MCP server
```

**Check if installed:**

```bash
npx --no-install playwright --version
```

**MCP configuration** (for Claude Code, OpenCode, etc.):

```json
{
  "playwright": {
    "command": "npx",
    "args": ["playwright-mcp@latest"]
  }
}
```

## Cross-Browser Testing

### **Multi-Browser Test Suite**

```javascript
// Test across different browsers
const browsers = ['chromium', 'firefox', 'webkit'];

for (const browserName of browsers) {
  await playwright.runTest({
    browser: browserName,
    url: "https://your-website.com",
    test: "login-flow"
  });
}
```

### **Browser-Specific Feature Testing**

```javascript
// Test browser-specific features
await playwright.testBrowserFeatures({
  url: "https://your-website.com",
  features: ["webgl", "webrtc", "geolocation", "notifications"],
  browsers: ["chromium", "firefox", "webkit"]
});
```

## 🔄 **Automated User Flows**

### **E-commerce Checkout Flow**

```javascript
// Automate complete checkout process
await playwright.automateFlow({
  url: "https://your-ecommerce.com",
  steps: [
    { action: "click", selector: ".product-card:first-child" },
    { action: "click", selector: ".add-to-cart" },
    { action: "click", selector: ".cart-icon" },
    { action: "fill", selector: "#email", value: "test@example.com" },
    { action: "fill", selector: "#password", value: "testpass123" },
    { action: "click", selector: ".checkout-button" }
  ]
});
```

### **Form Validation Testing**

```javascript
// Test form validation scenarios
await playwright.testFormValidation({
  url: "https://your-website.com/contact",
  form: "#contact-form",
  scenarios: [
    { field: "email", value: "invalid-email", expectError: true },
    { field: "phone", value: "123", expectError: true },
    { field: "message", value: "", expectError: true }
  ]
});
```

## 📱 **Mobile & Responsive Testing**

### **Device-Specific Testing**

```javascript
// Test on various mobile devices
const devices = [
  'iPhone 12',
  'iPhone 12 Pro Max',
  'Samsung Galaxy S21',
  'iPad Pro'
];

for (const device of devices) {
  await playwright.testOnDevice({
    device: device,
    url: "https://your-website.com",
    tests: ["navigation", "forms", "media-queries"]
  });
}
```

### **Orientation Testing**

```javascript
// Test portrait and landscape orientations
await playwright.testOrientations({
  url: "https://your-website.com",
  device: "iPhone 12",
  orientations: ["portrait", "landscape"],
  captureScreenshots: true
});
```

## 🎯 **Performance Testing**

### **Load Time Analysis**

```javascript
// Measure page load performance
await playwright.measurePerformance({
  url: "https://your-website.com",
  metrics: [
    "domContentLoaded",
    "load",
    "firstContentfulPaint",
    "largestContentfulPaint"
  ],
  iterations: 5
});
```

### **Network Throttling Tests**

```javascript
// Test under different network conditions
const networkConditions = [
  { name: "Fast 3G", downloadThroughput: 1.5 * 1024 * 1024 / 8 },
  { name: "Slow 3G", downloadThroughput: 500 * 1024 / 8 },
  { name: "Offline", offline: true }
];

for (const condition of networkConditions) {
  await playwright.testWithNetwork({
    url: "https://your-website.com",
    networkCondition: condition,
    timeout: 30000
  });
}
```

## 🔍 **Visual Testing & Screenshots**

### **Visual Regression Suite**

```javascript
// Comprehensive visual regression testing
await playwright.visualRegressionSuite({
  baseUrl: "https://your-website.com",
  pages: ["/", "/about", "/products", "/contact"],
  viewports: [
    { width: 1920, height: 1080 },
    { width: 1366, height: 768 },
    { width: 375, height: 667 }
  ],
  threshold: 0.2
});
```

### **Component Screenshot Testing**

```javascript
// Test individual components
await playwright.screenshotComponents({
  url: "https://your-website.com",
  components: [
    { selector: ".header", name: "header" },
    { selector: ".navigation", name: "nav" },
    { selector: ".hero-section", name: "hero" },
    { selector: ".footer", name: "footer" }
  ]
});
```

## 🛡️ **Security Testing**

### **XSS Vulnerability Testing**

```javascript
// Test for XSS vulnerabilities
await playwright.testXSS({
  url: "https://your-website.com",
  forms: ["#search-form", "#contact-form", "#login-form"],
  payloads: [
    "<script>alert('XSS')</script>",
    "javascript:alert('XSS')",
    "<img src=x onerror=alert('XSS')>"
  ]
});
```

### **Authentication Testing**

```javascript
// Test authentication flows
await playwright.testAuthentication({
  loginUrl: "https://your-website.com/login",
  credentials: {
    valid: { username: "testuser", password: "testpass" },
    invalid: { username: "invalid", password: "wrong" }
  },
  protectedUrls: ["/dashboard", "/profile", "/settings"]
});
```

## 📊 **API Testing Integration**

### **API Response Validation**

```javascript
// Test API endpoints through UI interactions
await playwright.testAPIIntegration({
  url: "https://your-website.com",
  interactions: [
    {
      action: "click",
      selector: ".load-more",
      expectAPI: {
        url: "/api/posts",
        method: "GET",
        status: 200
      }
    }
  ]
});
```

### **Real-time Data Testing**

```javascript
// Test real-time features
await playwright.testRealTimeFeatures({
  url: "https://your-chat-app.com",
  scenarios: [
    { action: "sendMessage", text: "Hello World" },
    { action: "expectMessage", text: "Hello World", timeout: 5000 }
  ]
});
```
