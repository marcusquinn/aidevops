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
/performance https://example.com                                    # Full audit
/performance https://example.com --categories=performance,accessibility
/performance http://localhost:3000                                   # Local dev
/performance https://example.com --compare baseline.json            # Before/after
```

<!-- AI-CONTEXT-END -->

Inspired by [@elithrar's web-perf agent skill](https://x.com/elithrar/status/2006028034889887973). Runs from within your repo so output becomes immediate context for making improvements.

## Setup

```bash
npm install -g chrome-devtools-mcp   # or: npx chrome-devtools-mcp@latest --headless
```

MCP config (headless or connect to existing browser):

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

For existing browser: replace `"--headless"` with `"--browserUrl", "http://127.0.0.1:9222"`.

## Usage Workflows

### Full Performance Audit

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

### Network Dependency Analysis

```javascript
await chromeDevTools.monitorNetwork({
  url: "https://your-site.com",
  filters: ["script", "xhr", "fetch"],
  captureHeaders: true,
  captureBody: false
});
// Look for: external domain scripts, long chains (A→B→C), bundles >100KB, render-blocking resources
```

### Local Development Testing

```javascript
// Start dev server first (e.g., npm run dev)
await chromeDevTools.lighthouse({ url: "http://localhost:3000", categories: ["performance"], device: "desktop" });
await chromeDevTools.captureConsole({ url: "http://localhost:3000", logLevel: "error", duration: 30000 });
```

### Before/After Comparison

```javascript
const baseline = await chromeDevTools.lighthouse({ url: "https://your-site.com", categories: ["performance"] });
// Save baseline.json, then after changes:
const after = await chromeDevTools.lighthouse({ url: "https://your-site.com", categories: ["performance"] });
// Compare: performance score delta, LCP improvement, CLS reduction, total blocking time change
```

### Accessibility Audit

```javascript
await chromeDevTools.lighthouse({ url: "https://your-site.com", categories: ["accessibility"], device: "desktop" });
// Check: missing alt text, low color contrast, missing form labels, keyboard nav, ARIA attributes
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

## Common Performance Issues & Fixes

### Slow LCP

Causes: large hero images, render-blocking CSS/JS, slow TTFB, client-side rendering delays.

```html
<!-- Preload critical images + use modern formats -->
<link rel="preload" as="image" href="/hero.webp">
<picture>
  <source srcset="/hero.avif" type="image/avif">
  <source srcset="/hero.webp" type="image/webp">
  <img src="/hero.jpg" alt="Hero" loading="eager" fetchpriority="high">
</picture>
```

### High CLS

Causes: images without dimensions, ads/embeds without reserved space, web fonts (FOUT/FOIT), dynamic content injection.

```html
<!-- Set dimensions; reserve space; use font-display: swap -->
<img src="/photo.jpg" width="800" height="600" alt="Photo">
<div style="min-height: 250px;"><!-- Ad or embed --></div>
```

```css
@font-face { font-family: 'Custom'; font-display: swap; src: url('/font.woff2') format('woff2'); }
```

### Poor FID/INP

Causes: long JS tasks (>50ms), heavy main thread, large bundles, synchronous third-party scripts.

```javascript
// Break up long tasks
function processItems(items) {
  const chunk = items.splice(0, 100);
  // Process chunk...
  if (items.length > 0) requestIdleCallback(() => processItems(items));
}
// Defer non-critical: <script src="/analytics.js" defer></script>
// Offload heavy work: const worker = new Worker('/heavy-task.js');
```

### Slow TTFB

Causes: slow DB queries, no caching, geographic distance, cold starts (serverless).

Fixes: CDN (Cloudflare, Fastly, Vercel Edge), caching (Redis/Memcached), query optimization, edge functions.

## Network Dependency Best Practices

### Third-Party Script Audit

```javascript
const thirdParty = requests.filter(r => !r.url.includes(yourDomain) && r.resourceType === 'script');
// Check: render-blocking, bundles >50KB, chains (A loads B), missing async/defer
```

### Bundle Size Analysis

```bash
npx source-map-explorer dist/main.js
gzip -c dist/main.js | wc -c   # Compressed size
```

### Request Chain Optimization

```html
<!-- Bad: sequential -->  <script src="/a.js"></script>
<!-- Good: parallel -->   <link rel="preload" as="script" href="/a.js">
                          <link rel="preload" as="script" href="/b.js">
```

## Integration with Existing Tools

```bash
# Quick audits
~/.aidevops/agents/scripts/pagespeed-helper.sh audit https://example.com

# Persistent browser session
~/.aidevops/agents/scripts/dev-browser-helper.sh start
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222
```

### CI/CD (GitHub Actions)

```yaml
- name: Performance Audit
  run: |
    npx lighthouse https://staging.example.com \
      --output=json --output-path=lighthouse.json \
      --chrome-flags="--headless"
    SCORE=$(jq '.categories.performance.score * 100 | round' lighthouse.json)
    if [ "$SCORE" -lt 90 ]; then echo "Score $SCORE below threshold (90)"; exit 1; fi
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
1. **CLS: 0.15** - Images without dimensions — `src/components/Hero.tsx:24` — Add `width`/`height`
2. **Render-blocking CSS** - `styles/fonts.css`, `styles/above-fold.css` — Inline critical, defer rest
3. **Large JS bundle** - 245KB gzipped — `dist/main.js` — Code split, lazy load routes

### Network Dependencies
- 3 third-party scripts (analytics, chat, fonts); longest chain: 3 requests (Google Fonts)
- Total blocking time: 120ms

### Accessibility: 92/100 — 2 issues: missing alt text (2 images)
```

## Related Resources

- [web.dev/vitals](https://web.dev/vitals/) — Core Web Vitals documentation
- [Chrome DevTools Performance](https://developer.chrome.com/docs/devtools/performance/)
- [Lighthouse Scoring](https://developer.chrome.com/docs/lighthouse/performance/performance-scoring/)
- [PageSpeed Insights](https://pagespeed.web.dev/)

## Related Subagents

- `tools/performance/webpagetest.md` — WebPageTest API for real-world multi-location testing
- `tools/browser/pagespeed.md` — PageSpeed Insights & Lighthouse CLI
- `tools/browser/chrome-devtools.md` — Chrome DevTools MCP integration
- `tools/browser/browser-automation.md` — Browser tool selection guide
