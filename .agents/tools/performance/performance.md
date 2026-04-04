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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

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

Inspired by [@elithrar's web-perf agent skill](https://x.com/elithrar/status/2006028034889887973). Runs from within your repo so output becomes immediate context for improvements.

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

```javascript
// --- Full Audit ---
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

// --- Network Dependencies ---
await chromeDevTools.monitorNetwork({
  url: "https://your-site.com",
  filters: ["script", "xhr", "fetch"],
  captureHeaders: true, captureBody: false
});
// Look for: external domain scripts, long chains (A->B->C), bundles >100KB, render-blocking resources

// --- Local Dev (start dev server first, e.g. npm run dev) ---
await chromeDevTools.lighthouse({ url: "http://localhost:3000", categories: ["performance"], device: "desktop" });
await chromeDevTools.captureConsole({ url: "http://localhost:3000", logLevel: "error", duration: 30000 });

// --- Before/After Comparison ---
const baseline = await chromeDevTools.lighthouse({ url: "https://your-site.com", categories: ["performance"] });
// Save baseline.json, make changes, then:
const after = await chromeDevTools.lighthouse({ url: "https://your-site.com", categories: ["performance"] });
// Compare: performance score delta, LCP improvement, CLS reduction, total blocking time change

// --- Accessibility ---
await chromeDevTools.lighthouse({ url: "https://your-site.com", categories: ["accessibility"], device: "desktop" });
// Check: missing alt text, low color contrast, missing form labels, keyboard nav, ARIA attributes
```

## Core Web Vitals Thresholds

| Metric | Good | Needs Improvement | Poor |
|--------|------|-------------------|------|
| **FCP** (First Contentful Paint) | <1.8s | 1.8s-3.0s | >3.0s |
| **LCP** (Largest Contentful Paint) | <2.5s | 2.5s-4.0s | >4.0s |
| **CLS** (Cumulative Layout Shift) | <0.1 | 0.1-0.25 | >0.25 |
| **FID** (First Input Delay) | <100ms | 100ms-300ms | >300ms |
| **TTFB** (Time to First Byte) | <800ms | 800ms-1800ms | >1800ms |
| **INP** (Interaction to Next Paint) | <200ms | 200ms-500ms | >500ms |

## Common Issues & Fixes

**Slow LCP** -- large hero images, render-blocking CSS/JS, slow TTFB, client-side rendering delays:

```html
<link rel="preload" as="image" href="/hero.webp">
<picture>
  <source srcset="/hero.avif" type="image/avif">
  <source srcset="/hero.webp" type="image/webp">
  <img src="/hero.jpg" alt="Hero" loading="eager" fetchpriority="high">
</picture>
```

**High CLS** -- images without dimensions, ads/embeds without reserved space, web fonts (FOUT/FOIT), dynamic content injection:

```html
<img src="/photo.jpg" width="800" height="600" alt="Photo">
<div style="min-height: 250px;"><!-- Ad or embed --></div>
```

```css
@font-face { font-family: 'Custom'; font-display: swap; src: url('/font.woff2') format('woff2'); }
```

**Poor FID/INP** -- long JS tasks (>50ms), heavy main thread, large bundles, synchronous third-party scripts:

```javascript
function processItems(items) {
  const chunk = items.splice(0, 100);
  if (items.length > 0) requestIdleCallback(() => processItems(items));
}
// Defer non-critical: <script src="/analytics.js" defer></script>
// Offload heavy work: const worker = new Worker('/heavy-task.js');
```

**Slow TTFB** -- slow DB queries, no caching, geographic distance, cold starts (serverless). Fixes: CDN (Cloudflare, Fastly, Vercel Edge), caching (Redis/Memcached), query optimization, edge functions.

## Network Dependency Best Practices

```javascript
// Third-party script audit
const thirdParty = requests.filter(r => !r.url.includes(yourDomain) && r.resourceType === 'script');
// Check: render-blocking, bundles >50KB, chains (A loads B), missing async/defer
```

```bash
npx source-map-explorer dist/main.js   # Bundle analysis
gzip -c dist/main.js | wc -c           # Compressed size
```

Request chain optimization: replace sequential `<script>` tags with `<link rel="preload" as="script">` for parallel loading.

## Integration

```bash
~/.aidevops/agents/scripts/pagespeed-helper.sh audit https://example.com  # Quick audit
~/.aidevops/agents/scripts/dev-browser-helper.sh start                    # Persistent browser
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222         # Connect to it
```

CI/CD (GitHub Actions):

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

Structure reports as:

```markdown
## Performance Report: example.com
| Metric | Value | Status | Target |
|--------|-------|--------|--------|
| LCP | 2.1s | GOOD | <2.5s |
| FID | 45ms | GOOD | <100ms |
| CLS | 0.15 | NEEDS WORK | <0.1 |
| TTFB | 650ms | GOOD | <800ms |

**Top Issues:** 1. CLS 0.15 - images without dimensions (`Hero.tsx:24`) 2. Render-blocking CSS (`fonts.css`) 3. Large JS bundle 245KB (`dist/main.js`)
**Network:** 3 third-party scripts; longest chain: 3 requests (Google Fonts); blocking time: 120ms
**Accessibility:** 92/100 - 2 missing alt text
```

## Related

**External**: [web.dev/vitals](https://web.dev/vitals/) | [Chrome DevTools Performance](https://developer.chrome.com/docs/devtools/performance/) | [Lighthouse Scoring](https://developer.chrome.com/docs/lighthouse/performance/performance-scoring/) | [PageSpeed Insights](https://pagespeed.web.dev/)

**Subagents**: `tools/performance/webpagetest.md` (multi-location testing) | `tools/browser/pagespeed.md` (Lighthouse CLI) | `tools/browser/chrome-devtools.md` (DevTools MCP) | `tools/browser/browser-automation.md` (tool selection)
