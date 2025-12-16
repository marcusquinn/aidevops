---
description: SEO site crawler with Screaming Frog-like capabilities
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Site Crawler - SEO Spider Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Comprehensive SEO site auditing like Screaming Frog
- **Helper**: `~/.aidevops/agents/scripts/site-crawler-helper.sh`
- **Browser Tools**: `tools/browser/crawl4ai.md`, `tools/browser/playwriter.md`
- **Output**: `~/Downloads/{domain}/{datestamp}/` with `_latest` symlink
- **Formats**: CSV, XLSX, JSON, HTML reports

**Commands**:

```bash
# Full site crawl
site-crawler-helper.sh crawl https://example.com

# Crawl with depth limit
site-crawler-helper.sh crawl https://example.com --depth 3 --max-urls 500

# Specific audits
site-crawler-helper.sh audit-links https://example.com
site-crawler-helper.sh audit-meta https://example.com
site-crawler-helper.sh audit-redirects https://example.com

# Export formats
site-crawler-helper.sh crawl https://example.com --format xlsx
site-crawler-helper.sh crawl https://example.com --format csv

# JavaScript rendering
site-crawler-helper.sh crawl https://example.com --render-js
```

**Key Features**:

- Broken link detection (4XX, 5XX errors)
- Redirect chain analysis
- Meta data auditing (titles, descriptions, robots)
- Duplicate content detection
- Structured data extraction
- XML sitemap generation
- Internal linking analysis
- JavaScript rendering support

<!-- AI-CONTEXT-END -->

## Overview

The Site Crawler agent provides Screaming Frog-like SEO auditing capabilities using
Crawl4AI, Playwriter, and custom scripts. It crawls websites to identify technical
SEO issues and exports findings to spreadsheets for analysis.

## Crawl Capabilities

### Core SEO Data Collection

| Category | Data Collected |
|----------|----------------|
| **URLs** | Address, status code, content type, response time, file size |
| **Page Titles** | Title text, length, missing/duplicate detection |
| **Meta Descriptions** | Description text, length, missing/duplicate detection |
| **Meta Robots** | Index/noindex, follow/nofollow, canonical, robots directives |
| **Headings** | H1, H2 content, missing/duplicate/multiple detection |
| **Links** | Internal/external, follow/nofollow, anchor text, broken links |
| **Images** | URL, alt text, file size, missing alt detection |
| **Redirects** | Type (301/302/307), chains, loops, final destination |
| **Canonicals** | Canonical URL, self-referencing, conflicts |
| **Hreflang** | Language codes, return links, conflicts |
| **Structured Data** | JSON-LD, Microdata, RDFa extraction and validation |

### Advanced Features

| Feature | Description |
|---------|-------------|
| **JavaScript Rendering** | Crawl SPAs (React, Vue, Angular) via Chromium |
| **Custom Extraction** | XPath, CSS selectors, regex for any HTML data |
| **Robots.txt Analysis** | Blocked URLs, directives, crawl delays |
| **XML Sitemap Analysis** | Parse sitemaps, find orphan/missing pages |
| **Duplicate Detection** | MD5 hash for exact duplicates, similarity scoring |
| **Crawl Depth** | Track URL depth in site architecture |
| **Word Count** | Content length analysis per page |

## Usage

### Basic Site Crawl

```bash
# Crawl entire site (respects robots.txt)
site-crawler-helper.sh crawl https://example.com

# Output: ~/Downloads/example.com/2025-01-15_143022/
#   - crawl-data.csv
#   - crawl-data.xlsx
#   - broken-links.csv
#   - redirects.csv
#   - meta-issues.csv
#   - summary.json
```

### Targeted Audits

```bash
# Broken links only
site-crawler-helper.sh audit-links https://example.com

# Meta data audit (titles, descriptions)
site-crawler-helper.sh audit-meta https://example.com

# Redirect audit
site-crawler-helper.sh audit-redirects https://example.com

# Duplicate content check
site-crawler-helper.sh audit-duplicates https://example.com

# Structured data validation
site-crawler-helper.sh audit-schema https://example.com
```

### Crawl Configuration

```bash
# Limit crawl scope
site-crawler-helper.sh crawl https://example.com \
  --depth 3 \
  --max-urls 1000 \
  --include "/blog/*" \
  --exclude "/admin/*,/wp-json/*"

# JavaScript rendering for SPAs
site-crawler-helper.sh crawl https://spa-site.com --render-js

# Custom user agent
site-crawler-helper.sh crawl https://example.com --user-agent "Googlebot"

# Respect/ignore robots.txt
site-crawler-helper.sh crawl https://example.com --ignore-robots
```

### Export Options

```bash
# CSV export (default)
site-crawler-helper.sh crawl https://example.com --format csv

# Excel export
site-crawler-helper.sh crawl https://example.com --format xlsx

# Both formats
site-crawler-helper.sh crawl https://example.com --format all

# Custom output location
site-crawler-helper.sh crawl https://example.com --output ~/SEO-Audits/
```

## Output Structure

All crawl outputs are organized by domain and timestamp:

```
~/Downloads/
└── example.com/
    ├── 2025-01-15_143022/
    │   ├── crawl-data.xlsx          # Full crawl data
    │   ├── crawl-data.csv           # Full crawl data (CSV)
    │   ├── broken-links.csv         # 4XX/5XX errors
    │   ├── redirects.csv            # All redirects with chains
    │   ├── meta-issues.csv          # Title/description issues
    │   ├── duplicate-content.csv    # Duplicate pages
    │   ├── images.csv               # Image audit
    │   ├── internal-links.csv       # Link structure
    │   ├── external-links.csv       # Outbound links
    │   ├── structured-data.json     # Schema.org data
    │   └── summary.json             # Crawl statistics
    ├── 2025-01-10_091500/
    │   └── ...
    └── _latest -> 2025-01-15_143022  # Symlink to latest
```

## Spreadsheet Columns

### Main Crawl Data (crawl-data.xlsx)

| Column | Description |
|--------|-------------|
| URL | Full page URL |
| Status Code | HTTP response code |
| Status | OK, Redirect, Client Error, Server Error |
| Content Type | MIME type |
| Title | Page title |
| Title Length | Character count |
| Meta Description | Description content |
| Description Length | Character count |
| H1 | First H1 content |
| H1 Count | Number of H1 tags |
| H2 | First H2 content |
| H2 Count | Number of H2 tags |
| Canonical | Canonical URL |
| Meta Robots | Robots directives |
| Word Count | Text content word count |
| Response Time | Server response in ms |
| File Size | Page size in bytes |
| Crawl Depth | Clicks from homepage |
| Inlinks | Number of internal links to page |
| Outlinks | Number of links from page |
| External Links | Number of external links |
| Images | Number of images |
| Images Missing Alt | Images without alt text |

### Broken Links Report

| Column | Description |
|--------|-------------|
| Broken URL | The 4XX/5XX URL |
| Status Code | Error code |
| Source URL | Page containing the link |
| Anchor Text | Link text |
| Link Type | Internal/External |

### Redirect Report

| Column | Description |
|--------|-------------|
| Original URL | Starting URL |
| Status Code | 301/302/307/308 |
| Redirect URL | Target URL |
| Final URL | End of chain |
| Chain Length | Number of hops |
| Chain | Full redirect path |

## Integration with Other Agents

### With E-E-A-T Score Agent

```bash
# Crawl site first
site-crawler-helper.sh crawl https://example.com --format json

# Then run E-E-A-T analysis on crawled pages
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json
```

### With PageSpeed Agent

```bash
# Crawl and get performance data
site-crawler-helper.sh crawl https://example.com --include-pagespeed
```

### With Crawl4AI

The site crawler uses Crawl4AI for:
- JavaScript rendering
- Structured data extraction
- LLM-powered content analysis
- CAPTCHA handling (with CapSolver)

See `tools/browser/crawl4ai.md` for advanced configuration.

## Browser Automation

For sites requiring authentication or complex interactions:

```bash
# Use Playwriter for authenticated crawls
site-crawler-helper.sh crawl https://example.com \
  --auth-type form \
  --login-url https://example.com/login \
  --username user@example.com \
  --password-env SITE_PASSWORD
```

See `tools/browser/playwriter.md` for browser automation details.

## XML Sitemap Generation

```bash
# Generate sitemap from crawl
site-crawler-helper.sh generate-sitemap https://example.com

# Output: ~/Downloads/example.com/_latest/sitemap.xml

# With configuration
site-crawler-helper.sh generate-sitemap https://example.com \
  --changefreq weekly \
  --priority-rules "/blog/*:0.8,/*:0.5" \
  --exclude "/admin/*,/private/*"
```

## Crawl Comparison

Compare two crawls to track changes:

```bash
# Compare latest with previous
site-crawler-helper.sh compare https://example.com

# Compare specific crawls
site-crawler-helper.sh compare \
  ~/Downloads/example.com/2025-01-10_091500 \
  ~/Downloads/example.com/2025-01-15_143022

# Output: changes-report.xlsx with:
#   - New URLs
#   - Removed URLs
#   - Changed titles/descriptions
#   - New/fixed broken links
#   - Redirect changes
```

## Configuration File

Create `~/.config/aidevops/site-crawler.json` for defaults:

```json
{
  "default_depth": 10,
  "max_urls": 10000,
  "respect_robots": true,
  "render_js": false,
  "user_agent": "AIDevOps-Crawler/1.0",
  "request_delay": 100,
  "concurrent_requests": 5,
  "timeout": 30,
  "output_format": "xlsx",
  "output_directory": "~/Downloads",
  "exclude_patterns": [
    "/wp-admin/*",
    "/wp-json/*",
    "*.pdf",
    "*.zip"
  ]
}
```

## Rate Limiting & Politeness

The crawler respects website resources:

- **Robots.txt**: Honored by default (override with `--ignore-robots`)
- **Crawl-delay**: Respected from robots.txt
- **Request delay**: Configurable delay between requests
- **Concurrent requests**: Limited to avoid overwhelming servers

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Crawl blocked | Check robots.txt, try different user-agent |
| JavaScript not rendering | Use `--render-js` flag |
| Missing pages | Increase `--depth` or check internal linking |
| Slow crawl | Reduce `--concurrent-requests` or increase `--request-delay` |
| Memory issues | Reduce `--max-urls` or use disk storage mode |

### Debug Mode

```bash
# Verbose output
site-crawler-helper.sh crawl https://example.com --verbose

# Save raw HTML for inspection
site-crawler-helper.sh crawl https://example.com --save-html
```

## Related Agents

- `seo/eeat-score.md` - E-E-A-T content quality scoring
- `tools/browser/crawl4ai.md` - AI-powered web crawling
- `tools/browser/playwriter.md` - Browser automation
- `tools/browser/pagespeed.md` - Performance auditing
- `seo/google-search-console.md` - Search performance data
