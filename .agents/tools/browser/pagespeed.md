---
description: PageSpeed Insights and Lighthouse performance testing
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

# PageSpeed Insights & Lighthouse Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `.agents/scripts/pagespeed-helper.sh`
- **Commands**: `audit [url]` | `lighthouse [url] [format]` | `accessibility [url]` | `wordpress [url]` | `bulk [file]` | `report [json]`
- **Install**: `brew install lighthouse jq bc` or `.agents/scripts/pagespeed-helper.sh install-deps`
- **API Key**: Optional but recommended - https://console.cloud.google.com/ → Enable PageSpeed Insights API
- **Core Web Vitals**: FCP (<1.8s), LCP (<2.5s), CLS (<0.1), FID (<100ms)
- **Accessibility**: Lighthouse accessibility score + failed audits (WCAG-mapped) — use `accessibility [url]`
- **Reports**: `~/.ai-devops/reports/pagespeed/`
- **Rate Limits**: 25 req/100s (no key), 25,000/day (with key)
- **WordPress**: Plugin audits, image optimization, caching recommendations
- **Deep a11y testing**: See `tools/accessibility/accessibility.md` for pa11y, contrast calculator, email checks
<!-- AI-CONTEXT-END -->

Comprehensive website performance auditing and optimization guidance for AI-assisted DevOps.

## Overview

This integration provides your AI assistant with powerful website performance and accessibility auditing capabilities using:

- **Google PageSpeed Insights API**: Real-time performance metrics and optimization suggestions
- **Lighthouse CLI**: Comprehensive auditing for performance, accessibility, SEO, and best practices
- **Lighthouse Accessibility**: First-class accessibility scoring with failed audit extraction and WCAG mapping
- **WordPress-specific analysis**: Tailored recommendations for WordPress websites
- **Bulk auditing**: Analyze multiple websites efficiently
- **MCP Integration**: Real-time performance data access for AI assistants

## Setup & Installation

### **Prerequisites**

```bash
# Install required dependencies
cd ~/Git/aidevops
./.agents/scripts/pagespeed-helper.sh install-deps

# This will install:
# - jq (JSON parsing)
# - Lighthouse CLI (npm install -g lighthouse)
# - bc (calculations)
```

### **Google API Key (Optional but Recommended)**

1. **Get API Key**:
   - Visit [Google Cloud Console](https://console.cloud.google.com/)
   - Enable PageSpeed Insights API
   - Create API key

2. **Configure API Key**:

   ```bash
   export GOOGLE_API_KEY="your-api-key-here"
   # Add to your shell profile for persistence
   echo 'export GOOGLE_API_KEY="your-api-key-here"' >> ~/.bashrc
   ```

### **MCP Server Setup**

```bash
# Install PageSpeed MCP server
npm install -g mcp-pagespeed-server

# Install Lighthouse MCP server (if available)
npm install -g lighthouse-mcp-server
```

## Usage Examples

### **Basic Website Audit**

```bash
# Audit a website (desktop & mobile)
./.agents/scripts/pagespeed-helper.sh audit https://example.com

# Lighthouse comprehensive audit
./.agents/scripts/pagespeed-helper.sh lighthouse https://example.com html
```

### **WordPress-Specific Analysis**

```bash
# WordPress performance analysis with specific recommendations
./.agents/scripts/pagespeed-helper.sh wordpress https://myblog.com
```

### **Bulk Website Auditing**

```bash
# Create URLs file
cat > websites.txt << EOF
https://site1.com
https://site2.com
https://site3.com
EOF

# Run bulk audit
./.agents/scripts/pagespeed-helper.sh bulk websites.txt
```

### **Generate Actionable Reports**

```bash
# Generate actionable recommendations from JSON report
./.agents/scripts/pagespeed-helper.sh report ~/.ai-devops/reports/pagespeed/lighthouse_20241110_143022.json
```

## AI Assistant Integration

### **System Prompt Addition**

Add this to your AI assistant's system prompt:

```text
For website performance optimization, use the PageSpeed and Lighthouse tools available in
~/Git/aidevops/.agents/scripts/pagespeed-helper.sh. Always provide specific,
actionable recommendations focusing on Core Web Vitals and user experience.
```

### **Common AI Assistant Tasks**

1. **Performance Audit**:

   ```text
   "Audit the performance of https://example.com and provide actionable recommendations"
   ```

2. **WordPress Optimization**:

   ```text
   "Analyze my WordPress site performance and suggest specific optimizations"
   ```

3. **Bulk Analysis**:

   ```text
   "Audit all websites in my portfolio and identify the top performance issues"
   ```

## Key Metrics Explained

### **Core Web Vitals**

- **First Contentful Paint (FCP)**: Time until first content appears
  - Good: < 1.8s | Needs Improvement: 1.8s - 3.0s | Poor: > 3.0s

- **Largest Contentful Paint (LCP)**: Time until largest content element loads
  - Good: < 2.5s | Needs Improvement: 2.5s - 4.0s | Poor: > 4.0s

- **Cumulative Layout Shift (CLS)**: Visual stability measure
  - Good: < 0.1 | Needs Improvement: 0.1 - 0.25 | Poor: > 0.25

- **First Input Delay (FID)**: Interactivity responsiveness
  - Good: < 100ms | Needs Improvement: 100ms - 300ms | Poor: > 300ms

### **Additional Metrics**

- **Time to First Byte (TTFB)**: Server response time
- **Speed Index**: How quickly content is visually displayed
- **Total Blocking Time**: Time when main thread is blocked

## Lighthouse Accessibility Output

Lighthouse accessibility is surfaced as first-class output alongside performance. Every `lighthouse` and `accessibility` command extracts the accessibility score, failed audits, and WCAG-mapped issues.

### Accessibility Audit

```bash
# Dedicated accessibility audit (extracts score + failed audits from Lighthouse)
./.agents/scripts/pagespeed-helper.sh accessibility https://example.com

# Lighthouse JSON also includes accessibility detail automatically
./.agents/scripts/pagespeed-helper.sh lighthouse https://example.com json
```

### Output Format

The accessibility output includes:

- **Accessibility score** (0-100%) with color-coded pass/fail
- **Failed audits** grouped by WCAG category:
  - Contrast (WCAG 1.4.3 / 1.4.6)
  - ARIA attributes (WCAG 4.1.2)
  - Labels and names (WCAG 1.1.1, 1.3.1, 2.4.6)
  - Keyboard and focus (WCAG 2.1.1, 2.4.7)
  - Structure and semantics (WCAG 1.3.1, 2.4.1)
- **Passing audit count** for quick health check

### Interpreting Scores

| Score | Rating | Action |
|-------|--------|--------|
| 90-100 | Good | Minor issues only, address at next opportunity |
| 50-89 | Needs improvement | Fix failed audits before next release |
| 0-49 | Poor | Critical accessibility barriers — fix immediately |

### Relationship to Dedicated Accessibility Testing

This integration provides Lighthouse-based accessibility scoring as part of performance workflows. For deeper testing, use the dedicated accessibility subagent:

| Need | Tool |
|------|------|
| Quick score + top failures | `pagespeed-helper.sh accessibility [url]` |
| WCAG-specific violation report | `accessibility-helper.sh pa11y [url]` |
| Contrast ratio checking | `accessibility-helper.sh contrast [fg] [bg]` |
| Email HTML accessibility | `accessibility-helper.sh email [file]` |
| Full audit (Lighthouse + pa11y) | `accessibility-helper.sh audit [url]` |

See `tools/accessibility/accessibility.md` for the full accessibility subagent.

## WordPress-Specific Optimizations

### **Common Issues & Solutions**

1. **Plugin Performance**:
   - Audit active plugins with Query Monitor
   - Disable unnecessary plugins
   - Use lightweight alternatives

2. **Image Optimization**:
   - Convert to WebP format
   - Implement lazy loading
   - Use proper image dimensions

3. **Caching Implementation**:
   - Page caching: WP Rocket, W3 Total Cache
   - Object caching: Redis, Memcached
   - CDN integration: Cloudflare, MaxCDN

4. **Database Optimization**:
   - Clean up post revisions
   - Remove spam comments
   - Optimize database tables

5. **Theme & Code Optimization**:
   - Use lightweight themes
   - Minimize CSS/JS files
   - Remove unused code

## Report Storage

All reports are saved to: `~/.ai-devops/reports/pagespeed/`

### **Report Types**

- **PageSpeed JSON**: `pagespeed_YYYYMMDD_HHMMSS_desktop.json`
- **Lighthouse HTML**: `lighthouse_YYYYMMDD_HHMMSS.html`
- **Lighthouse JSON**: `lighthouse_YYYYMMDD_HHMMSS.json`

## Advanced Usage

### **Custom Lighthouse Configuration**

```bash
# Run Lighthouse with specific categories
lighthouse https://example.com \
  --only-categories=performance,accessibility \
  --output=json \
  --output-path=custom-report.json
```

### **API Rate Limits**

- **Without API Key**: 25 requests per 100 seconds
- **With API Key**: 25,000 requests per day

### **Automation Integration**

```bash
# Add to cron for regular monitoring
0 9 * * 1 /path/to/pagespeed-helper.sh bulk /path/to/websites.txt
```

## Related Resources

- **[Google PageSpeed Insights](https://pagespeed.web.dev/)**
- **[Lighthouse Documentation](https://developers.google.com/web/tools/lighthouse)**
- **[Core Web Vitals](https://web.dev/vitals/)**
- **[WCAG 2.1 Guidelines](https://www.w3.org/TR/WCAG21/)**
- **[WordPress Performance Guide](https://wordpress.org/support/article/optimization/)**
- `tools/accessibility/accessibility.md` — Dedicated accessibility subagent (pa11y, contrast, email)

## MCP Integration

The PageSpeed MCP server provides real-time access to performance data for AI assistants:

```json
{
  "pagespeed_audit": "Audit website performance",
  "lighthouse_analysis": "Comprehensive website analysis",
  "accessibility_audit": "Lighthouse accessibility score and failed audits",
  "performance_metrics": "Get Core Web Vitals",
  "optimization_recommendations": "Get actionable improvements"
}
```

This enables AI assistants to provide immediate, data-driven performance and accessibility guidance.
