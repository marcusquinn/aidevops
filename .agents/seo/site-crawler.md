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

- **Helper**: `~/.aidevops/agents/scripts/site-crawler-helper.sh`
- **Browser Tools**: `tools/browser/crawl4ai.md`, `tools/browser/playwriter.md`
- **Output**: `~/Downloads/{domain}/{datestamp}/` with `_latest` symlink
- **Formats**: CSV, XLSX, JSON, HTML reports

```bash
site-crawler-helper.sh crawl https://example.com                          # Full crawl
site-crawler-helper.sh crawl https://example.com --depth 3 --max-urls 500
site-crawler-helper.sh crawl https://example.com --render-js              # SPAs
site-crawler-helper.sh crawl https://example.com --format xlsx
site-crawler-helper.sh audit-links https://example.com
site-crawler-helper.sh audit-meta https://example.com
site-crawler-helper.sh audit-redirects https://example.com
site-crawler-helper.sh audit-duplicates https://example.com
site-crawler-helper.sh audit-schema https://example.com
```

<!-- AI-CONTEXT-END -->

## Crawl Capabilities

### Core SEO Data

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

### Crawl Configuration

```bash
# Scope limiting
site-crawler-helper.sh crawl https://example.com \
  --depth 3 --max-urls 1000 \
  --include "/blog/*" --exclude "/admin/*,/wp-json/*"

# JavaScript rendering for SPAs
site-crawler-helper.sh crawl https://spa-site.com --render-js

# Custom user agent / robots override
site-crawler-helper.sh crawl https://example.com --user-agent "Googlebot"
site-crawler-helper.sh crawl https://example.com --ignore-robots

# Export format
site-crawler-helper.sh crawl https://example.com --format all   # csv + xlsx
site-crawler-helper.sh crawl https://example.com --output ~/SEO-Audits/
```

### Authenticated Crawls

```bash
site-crawler-helper.sh crawl https://example.com \
  --auth-type form \
  --login-url https://example.com/login \
  --username user@example.com \
  --password-env SITE_PASSWORD
```

See `tools/browser/playwriter.md` for browser automation details.

### XML Sitemap Generation

```bash
site-crawler-helper.sh generate-sitemap https://example.com
site-crawler-helper.sh generate-sitemap https://example.com \
  --changefreq weekly \
  --priority-rules "/blog/*:0.8,/*:0.5" \
  --exclude "/admin/*,/private/*"
# Output: ~/Downloads/example.com/_latest/sitemap.xml
```

### Crawl Comparison

```bash
site-crawler-helper.sh compare https://example.com              # latest vs previous
site-crawler-helper.sh compare \
  ~/Downloads/example.com/2025-01-10_091500 \
  ~/Downloads/example.com/2025-01-15_143022
# Output: changes-report.xlsx (new/removed URLs, changed meta, redirect changes)
```

### Debug

```bash
site-crawler-helper.sh crawl https://example.com --verbose
site-crawler-helper.sh crawl https://example.com --save-html
```

## Output Structure

```text
~/Downloads/example.com/
├── 2025-01-15_143022/
│   ├── crawl-data.xlsx          # Full crawl data
│   ├── crawl-data.csv
│   ├── broken-links.csv         # 4XX/5XX errors
│   ├── redirects.csv            # Redirect chains
│   ├── meta-issues.csv          # Title/description issues
│   ├── duplicate-content.csv
│   ├── images.csv
│   ├── internal-links.csv
│   ├── external-links.csv
│   ├── structured-data.json
│   └── summary.json
└── _latest -> 2025-01-15_143022
```

## Spreadsheet Columns

### crawl-data.xlsx

| Column | Description |
|--------|-------------|
| URL | Full page URL |
| Status Code | HTTP response code |
| Status | OK / Redirect / Client Error / Server Error |
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
| Inlinks | Internal links to page |
| Outlinks | Links from page |
| External Links | External links from page |
| Images | Number of images |
| Images Missing Alt | Images without alt text |

### broken-links.csv

| Column | Description |
|--------|-------------|
| Broken URL | The 4XX/5XX URL |
| Status Code | Error code |
| Source URL | Page containing the link |
| Anchor Text | Link text |
| Link Type | Internal/External |

### redirects.csv

| Column | Description |
|--------|-------------|
| Original URL | Starting URL |
| Status Code | 301/302/307/308 |
| Redirect URL | Target URL |
| Final URL | End of chain |
| Chain Length | Number of hops |
| Chain | Full redirect path |

## Configuration

`~/.config/aidevops/site-crawler.json`:

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
  "exclude_patterns": ["/wp-admin/*", "/wp-json/*", "*.pdf", "*.zip"]
}
```

## Rate Limiting & Politeness

- Robots.txt honored by default (`--ignore-robots` to override)
- Crawl-delay directive respected from robots.txt
- Request delay and concurrent requests configurable (see config above)

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Crawl blocked | Check robots.txt, try different user-agent |
| JavaScript not rendering | Use `--render-js` flag |
| Missing pages | Increase `--depth` or check internal linking |
| Slow crawl | Reduce `--concurrent-requests` or increase `--request-delay` |
| Memory issues | Reduce `--max-urls` or use disk storage mode |

## Integration

- **E-E-A-T**: `eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json`
- **PageSpeed**: `site-crawler-helper.sh crawl https://example.com --include-pagespeed`
- **Crawl4AI**: JS rendering, structured data extraction, LLM content analysis, CAPTCHA handling — see `tools/browser/crawl4ai.md`

## Related Agents

- `seo/eeat-score.md` — E-E-A-T content quality scoring
- `tools/browser/crawl4ai.md` — AI-powered web crawling
- `tools/browser/playwriter.md` — Browser automation
- `tools/browser/pagespeed.md` — Performance auditing
- `seo/google-search-console.md` — Search performance data
