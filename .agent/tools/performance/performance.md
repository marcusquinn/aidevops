---
description: Web performance analysis - Core Web Vitals, network dependencies, accessibility
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
mcp:
  - chrome-devtools-mcp
---

# Web Performance Analysis

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Comprehensive web performance analysis from within your repo
- **Dependencies**: Chrome DevTools MCP (`npx chrome-devtools-mcp@latest`)
- **Core Metrics**: FCP (<1.8s), LCP (<2.5s), CLS (<0.1), FID (<100ms), TTFB (<800ms)
- **Categories**: Performance, Network Dependencies, Core Web Vitals, Accessibility
- **Related**: `tools/browser/pagespeed.md`, `tools/browser/chrome-devtools.md`

**Quick commands**:

```bash
# Full performance audit (Lighthouse + Core Web Vitals)
/performance https://example.com

# Specific categories
/performance https://example.com --categories=performance,accessibility

# Local dev server
/performance http://localhost:3000

# Compare before/after
/performance https://example.com --compare baseline.json
```

<!-- AI-CONTEXT-END -->

## Overview

This subagent provides comprehensive web performance analysis inspired by [@elithrar's web-perf agent skill](https://x.com/elithrar/status/2006028034889887973). It uses Chrome DevTools MCP to assess:

1. **Core Web Vitals** - FCP, LCP, CLS, FID, TTFB
2. **Performance** - Load times, render blocking, JavaScript execution
3. **Network Dependencies** - Third-party scripts, request chains, bundle sizes
4. **Accessibility** - WCAG compliance, keyboard navigation, screen reader support

The key advantage: running from within your repo means the output becomes immediate context for making improvements.

## Setup

### Chrome DevTools MCP

```bash
# Install globally (recommended)
npm install -g chrome-devtools-mcp

# Or run via npx
npx chrome-devtools-mcp@latest --headless
```

### MCP Configuration

Add to your MCP config (Claude Code, OpenCode, etc.):

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["chrome-devtools-mcp@latest", "--headless"]
    }
  }
}
```

For connecting to an existing browser:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["chrome-devtools-mcp@latest", "--browserUrl", "http://127.0.0.1:9222"]
    }
  }
}
```

## Usage Workflows

### 1. Full Performance Audit

Run a comprehensive Lighthouse audit with Core Web Vitals:

```javascript
// Via Chrome DevTools MCP
await chromeDevTools.lighthouse({
  url: "https://your-site.com",
  categories: ["performance", "accessibility", "best-practices", "seo"],
  device: "mobile"  // or "desktop"
});

// Get Core Web Vitals
await chromeDevTools.measureWebVitals({
  url: "https://your-site.com",
  metrics: ["LCP", "FID", "CLS", "TTFB", "FCP"],
  iterations: 3  // Average over multiple runs
});
```

### 2. Network Dependency Analysis

Identify third-party scripts and request chains impacting performance:

```javascript
// Monitor network requests
await chromeDevTools.monitorNetwork({
  url: "https://your-site.com",
  filters: ["script", "xhr", "fetch"],
  captureHeaders: true,
  captureBody: false
});

// Analyze third-party impact
// Look for:
// - Scripts from external domains
// - Long request chains (A -> B -> C)
// - Large bundle sizes (>100KB compressed)
// - Render-blocking resources
```

### 3. Local Development Testing

Test your local dev server before deploying:

```javascript
// Start your dev server first (e.g., npm run dev)
await chromeDevTools.lighthouse({
  url: "http://localhost:3000",
  categories: ["performance"],
  device: "desktop"
});

// Monitor for console errors during interaction
await chromeDevTools.captureConsole({
  url: "http://localhost:3000",
  logLevel: "error",
  duration: 30000
});
```

### 4. Before/After Comparison

Compare performance before and after changes:

```javascript
// Baseline (save results)
const baseline = await chromeDevTools.lighthouse({
  url: "https://your-site.com",
  categories: ["performance"]
});
// Save baseline.json

// After changes
const after = await chromeDevTools.lighthouse({
  url: "https://your-site.com",
  categories: ["performance"]
});

// Compare key metrics:
// - Performance score delta
// - LCP improvement
// - CLS reduction
// - Total blocking time change
```

### 5. Accessibility Audit

Check WCAG compliance and accessibility issues:

```javascript
await chromeDevTools.lighthouse({
  url: "https://your-site.com",
  categories: ["accessibility"],
  device: "desktop"
});

// Common issues to check:
// - Missing alt text on images
// - Low color contrast
// - Missing form labels
// - Keyboard navigation issues
// - ARIA attribute problems
```

## Core Web Vitals Thresholds

| Metric | Good | Needs Improvement | Poor |
|--------|------|-------------------|------|
| **FCP** (First Contentful Paint) | <1.8s | 1.8s - 3.0s | >3.0s |
| **LCP** (Largest Contentful Paint) | <2.5s | 2.5s - 4.0s | >4.0s |
| **CLS** (Cumulative Layout Shift) | <0.1 | 0.1 - 0.25 | >0.25 |
| **FID** (First Input Delay) | <100ms | 100ms - 300ms | >300ms |
| **TTFB** (Time to First Byte) | <800ms | 800ms - 1800ms | >1800ms |
| **INP** (Interaction to Next Paint) | <200ms | 200ms - 500ms | >500ms |

## Common Performance Issues & Fixes

### Slow LCP

**Causes**:
- Large hero images not optimized
- Render-blocking CSS/JS
- Slow server response (TTFB)
- Client-side rendering delays

**Fixes**:

```html
<!-- Preload critical images -->
<link rel="preload" as="image" href="/hero.webp">

<!-- Use modern image formats -->
<picture>
  <source srcset="/hero.avif" type="image/avif">
  <source srcset="/hero.webp" type="image/webp">
  <img src="/hero.jpg" alt="Hero" loading="eager" fetchpriority="high">
</picture>
```

### High CLS

**Causes**:
- Images without dimensions
- Ads/embeds without reserved space
- Web fonts causing FOUT/FOIT
- Dynamic content injection

**Fixes**:

```html
<!-- Always set dimensions -->
<img src="/photo.jpg" width="800" height="600" alt="Photo">

<!-- Reserve space for dynamic content -->
<div style="min-height: 250px;">
  <!-- Ad or embed loads here -->
</div>

<!-- Font display swap -->
@font-face {
  font-family: 'Custom';
  font-display: swap;
  src: url('/font.woff2') format('woff2');
}
```

### Poor FID/INP

**Causes**:
- Long JavaScript tasks (>50ms)
- Heavy main thread work
- Large JavaScript bundles
- Synchronous third-party scripts

**Fixes**:

```javascript
// Break up long tasks
function processItems(items) {
  const chunk = items.splice(0, 100);
  // Process chunk...
  if (items.length > 0) {
    requestIdleCallback(() => processItems(items));
  }
}

// Defer non-critical JS
<script src="/analytics.js" defer></script>

// Use web workers for heavy computation
const worker = new Worker('/heavy-task.js');
```

### Slow TTFB

**Causes**:
- Slow database queries
- No caching
- Geographic distance to server
- Cold starts (serverless)

**Fixes**:
- Add CDN (Cloudflare, Fastly, Vercel Edge)
- Implement caching (Redis, Memcached)
- Optimize database queries
- Use edge functions for dynamic content

## Network Dependency Best Practices

### Third-Party Script Audit

```javascript
// Identify third-party scripts
const thirdParty = requests.filter(r =>
  !r.url.includes(yourDomain) &&
  r.resourceType === 'script'
);

// Check for:
// 1. Scripts blocking render
// 2. Large bundle sizes (>50KB)
// 3. Long chains (script A loads script B)
// 4. Scripts without async/defer
```

### Bundle Size Analysis

```bash
# Analyze JavaScript bundles
npx source-map-explorer dist/main.js

# Check compressed sizes
ls -la dist/*.js | awk '{print $5, $9}'
gzip -c dist/main.js | wc -c  # Compressed size
```

### Request Chain Optimization

```html
<!-- Bad: Sequential loading -->
<script src="/a.js"></script>  <!-- Loads b.js -->
<script src="/b.js"></script>  <!-- Loads c.js -->

<!-- Good: Parallel with preload -->
<link rel="preload" as="script" href="/a.js">
<link rel="preload" as="script" href="/b.js">
<link rel="preload" as="script" href="/c.js">
```

## Integration with Existing Tools

### With PageSpeed Helper

```bash
# Use pagespeed-helper.sh for quick audits
~/.aidevops/agents/scripts/pagespeed-helper.sh audit https://example.com

# Use Chrome DevTools MCP for deeper analysis
npx chrome-devtools-mcp@latest --headless
```

### With Browser Automation

```bash
# Start dev-browser for persistent testing
~/.aidevops/agents/scripts/dev-browser-helper.sh start

# Connect Chrome DevTools MCP
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222
```

### With CI/CD

```yaml
# GitHub Actions example
- name: Performance Audit
  run: |
    npx lighthouse https://staging.example.com \
      --output=json \
      --output-path=lighthouse.json \
      --chrome-flags="--headless"

    # Check performance score
    SCORE=$(jq '.categories.performance.score * 100 | round' lighthouse.json)
    if [ "$SCORE" -lt 90 ]; then
      echo "Performance score $SCORE is below threshold (90)"
      exit 1
    fi
```

## Actionable Output Format

When running performance analysis, provide output in this format for immediate action:

```markdown
## Performance Report: example.com

### Core Web Vitals
| Metric | Value | Status | Target |
|--------|-------|--------|--------|
| LCP | 2.1s | GOOD | <2.5s |
| FID | 45ms | GOOD | <100ms |
| CLS | 0.15 | NEEDS WORK | <0.1 |
| TTFB | 650ms | GOOD | <800ms |

### Top Issues (Priority Order)
1. **CLS: 0.15** - Images without dimensions
   - File: `src/components/Hero.tsx:24`
   - Fix: Add `width` and `height` attributes

2. **Render-blocking CSS** - 2 stylesheets
   - Files: `styles/fonts.css`, `styles/above-fold.css`
   - Fix: Inline critical CSS, defer non-critical

3. **Large JavaScript bundle** - 245KB (gzipped)
   - File: `dist/main.js`
   - Fix: Code split, lazy load routes

### Network Dependencies
- 3 third-party scripts (analytics, chat, fonts)
- Longest chain: 3 requests (Google Fonts)
- Total blocking time: 120ms

### Accessibility
- Score: 92/100
- 2 issues: Missing alt text (2 images)
```

## Related Resources

- [web.dev/vitals](https://web.dev/vitals/) - Core Web Vitals documentation
- [Chrome DevTools Performance](https://developer.chrome.com/docs/devtools/performance/)
- [Lighthouse Scoring](https://developer.chrome.com/docs/lighthouse/performance/performance-scoring/)
- [PageSpeed Insights](https://pagespeed.web.dev/)

## Related Subagents

- `tools/browser/pagespeed.md` - PageSpeed Insights & Lighthouse CLI
- `tools/browser/chrome-devtools.md` - Chrome DevTools MCP integration
- `tools/browser/browser-automation.md` - Browser tool selection guide
