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

- **Dependencies**: Chrome DevTools MCP (`npx chrome-devtools-mcp@latest`)
- **Core Metrics**: FCP (<1.8s), LCP (<2.5s), CLS (<0.1), FID (<100ms), TTFB (<800ms)
- **Related**: `tools/browser/pagespeed.md`, `tools/browser/chrome-devtools.md`

```bash
/performance https://example.com                                    # full audit
/performance https://example.com --categories=performance,accessibility
/performance http://localhost:3000                                   # local dev
/performance https://example.com --compare baseline.json            # before/after
```

<!-- AI-CONTEXT-END -->

Uses Chrome DevTools MCP to assess Core Web Vitals, load performance, network dependencies, and accessibility. Running from within your repo makes output immediately actionable for fixes.

## Setup

```bash
npm install -g chrome-devtools-mcp
```

MCP config (headless):

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

Connect to existing browser: replace `"--headless"` with `"--browserUrl", "http://127.0.0.1:9222"`.

## Usage Workflows

### 1. Full Performance Audit

```javascript
await chromeDevTools.lighthouse({
  url: "https://your-site.com",
  categories: ["performance", "accessibility", "best-practices", "seo"],
  device: "mobile"  // or "desktop"
});

await chromeDevTools.measureWebVitals({
  url: "https://your-site.com",
  metrics: ["LCP", "FID", "CLS", "TTFB", "FCP"],
  iterations: 3
});
```

### 2. Network Dependency Analysis

```javascript
await chromeDevTools.monitorNetwork({
  url: "https://your-site.com",
  filters: ["script", "xhr", "fetch"],
  captureHeaders: true,
  captureBody: false
});
// Flag: external domains, chains (A→B→C), bundles >100KB, render-blocking resources
```

### 3. Local Development Testing

```javascript
await chromeDevTools.lighthouse({ url: "http://localhost:3000", categories: ["performance"], device: "desktop" });
await chromeDevTools.captureConsole({ url: "http://localhost:3000", logLevel: "error", duration: 30000 });
```

### 4. Before/After Comparison

```javascript
const baseline = await chromeDevTools.lighthouse({ url: "https://your-site.com", categories: ["performance"] });
// save baseline.json, then after changes:
const after = await chromeDevTools.lighthouse({ url: "https://your-site.com", categories: ["performance"] });
// Compare: performance score delta, LCP improvement, CLS reduction, total blocking time
```

### 5. Accessibility Audit

```javascript
await chromeDevTools.lighthouse({ url: "https://your-site.com", categories: ["accessibility"], device: "desktop" });
// Check: alt text, color contrast, form labels, keyboard nav, ARIA attributes
```

## Core Web Vitals Thresholds

| Metric | Good | Needs Improvement | Poor |
|--------|------|-------------------|------|
| **FCP** (First Contentful Paint) | <1.8s | 1.8s–3.0s | >3.0s |
| **LCP** (Largest Contentful Paint) | <2.5s | 2.5s–4.0s | >4.0s |
| **CLS** (Cumulative Layout Shift) | <0.1 | 0.1–0.25 | >0.25 |
| **FID** (First Input Delay) | <100ms | 100ms–300ms | >300ms |
| **TTFB** (Time to First Byte) | <800ms | 800ms–1800ms | >1800ms |
| **INP** (Interaction to Next Paint) | <200ms | 200ms–500ms | >500ms |

## Common Issues & Fixes

### Slow LCP
Causes: large hero images, render-blocking CSS/JS, slow TTFB, CSR delays.

```html
<link rel="preload" as="image" href="/hero.webp">
<picture>
  <source srcset="/hero.avif" type="image/avif">
  <source srcset="/hero.webp" type="image/webp">
  <img src="/hero.jpg" alt="Hero" loading="eager" fetchpriority="high">
</picture>
```

### High CLS
Causes: images without dimensions, ads without reserved space, web fonts (FOUT/FOIT), dynamic injection.

```html
<img src="/photo.jpg" width="800" height="600" alt="Photo">
<div style="min-height: 250px;"><!-- reserved for ad/embed --></div>
```

```css
@font-face { font-family: 'Custom'; font-display: swap; src: url('/font.woff2') format('woff2'); }
```

### Poor FID/INP
Causes: long JS tasks (>50ms), heavy main thread, large bundles, synchronous third-party scripts.

```javascript
function processItems(items) {
  const chunk = items.splice(0, 100);
  if (items.length > 0) requestIdleCallback(() => processItems(items));
}
// Also: <script src="/analytics.js" defer></script>
// Also: const worker = new Worker('/heavy-task.js');
```

### Slow TTFB
Add CDN (Cloudflare, Fastly, Vercel Edge), implement caching (Redis/Memcached), optimize DB queries, use edge functions.

## Network Dependency Best Practices

```javascript
// Third-party audit
const thirdParty = requests.filter(r => !r.url.includes(yourDomain) && r.resourceType === 'script');
// Flag: render-blocking, >50KB bundles, load chains, missing async/defer
```

```bash
npx source-map-explorer dist/main.js   # bundle analysis
gzip -c dist/main.js | wc -c           # compressed size
```

```html
<!-- Parallel preload instead of sequential script tags -->
<link rel="preload" as="script" href="/a.js">
<link rel="preload" as="script" href="/b.js">
<link rel="preload" as="script" href="/c.js">
```

## Integration

```bash
# Quick audit
~/.aidevops/agents/scripts/pagespeed-helper.sh audit https://example.com

# Persistent browser session
~/.aidevops/agents/scripts/dev-browser-helper.sh start
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222
```

CI/CD (GitHub Actions):

```yaml
- name: Performance Audit
  run: |
    npx lighthouse https://staging.example.com \
      --output=json --output-path=lighthouse.json --chrome-flags="--headless"
    SCORE=$(jq '.categories.performance.score * 100 | round' lighthouse.json)
    [ "$SCORE" -lt 90 ] && echo "Score $SCORE below threshold (90)" && exit 1
```

## Actionable Output Format

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
2. **Render-blocking CSS** - 2 stylesheets (`styles/fonts.css`, `styles/above-fold.css`)
   - Fix: Inline critical CSS, defer non-critical
3. **Large JS bundle** - 245KB gzipped (`dist/main.js`)
   - Fix: Code split, lazy load routes

### Network Dependencies
- 3 third-party scripts (analytics, chat, fonts)
- Longest chain: 3 requests (Google Fonts); total blocking time: 120ms

### Accessibility
- Score: 92/100 — 2 issues: missing alt text
```

## Related

- [web.dev/vitals](https://web.dev/vitals/) — Core Web Vitals docs
- [Chrome DevTools Performance](https://developer.chrome.com/docs/devtools/performance/)
- [Lighthouse Scoring](https://developer.chrome.com/docs/lighthouse/performance/performance-scoring/)
- [PageSpeed Insights](https://pagespeed.web.dev/)
- `tools/performance/webpagetest.md` — WebPageTest API (real-world, multi-location)
- `tools/browser/pagespeed.md` — PageSpeed Insights & Lighthouse CLI
- `tools/browser/chrome-devtools.md` — Chrome DevTools MCP integration
- `tools/browser/browser-automation.md` — browser tool selection guide
