---
description: SEO site crawler helper - LibreCrawl, Crawl4AI and fallback engines
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Site Crawler - SEO Spider Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `~/.aidevops/agents/scripts/site-crawler-helper.sh`
- **Engines**: LibreCrawl (`seo/librecrawl.md`), Crawl4AI (`tools/browser/crawl4ai.md`), built-in Python fallback
- **Output**: `~/Downloads/{domain}/{timestamp}/` with a `_latest` symlink; CSV, `summary.json`, optional XLSX
- **Engine choice**: `--engine auto` (default) uses LibreCrawl when it answers in local mode at `LIBRECRAWL_URL`, else Crawl4AI at `http://localhost:11235`, else the fallback

```bash
site-crawler-helper.sh status                                    # which engines are available
site-crawler-helper.sh crawl https://example.com                 # auto engine
site-crawler-helper.sh crawl https://example.com --depth 3 --max-urls 500
site-crawler-helper.sh crawl https://example.com --engine librecrawl --render-js
site-crawler-helper.sh audit-links https://example.com           # crawl, max 200 URLs
site-crawler-helper.sh generate-sitemap https://example.com      # from the latest crawl
```

<!-- AI-CONTEXT-END -->

## Commands

| Command | What it does |
|---------|--------------|
| `crawl <url> [options]` | Crawl and write the output files below |
| `audit-links`, `audit-meta`, `audit-redirects <url> [options]` | The same crawl with `--max-urls 200` by default; read `broken-links.csv`, `meta-issues.csv` or `redirects.csv` |
| `generate-sitemap <url>` | `sitemap.xml` of the 200-status URLs in `~/Downloads/{domain}/_latest/crawl-data.csv` (fixed `weekly` / `0.5`; ignores `--output`) |
| `compare <url>` or `compare <dir1> <dir2>` | URL counts of the two latest (or given) crawls |
| `status` | LibreCrawl reachability and local mode, Crawl4AI, Python packages, jq, curl |

Not implemented by any engine: duplicate or schema audits as commands (LibreCrawl reports near-duplicates in `librecrawl-issues.csv` and JSON-LD in `librecrawl-urls.json`), authenticated crawls, custom XPath/CSS extraction, a config file, `--verbose`/`--save-html`, change reports from `compare`.

## Options and engines

| Option | LibreCrawl | Crawl4AI | Fallback |
|--------|:----------:|:--------:|:--------:|
| `--depth N`, `--max-urls N` | yes (depth 1–10) | yes | yes |
| `--output DIR` | yes | yes | yes |
| `--format csv\|xlsx\|all` (default `xlsx`) | XLSX unless `csv` | XLSX if openpyxl | yes |
| `--render-js` | yes | rejected | rejected |
| `--user-agent UA` | yes | rejected | rejected |
| `--ignore-robots` (robots.txt obeyed by default) | yes | rejected | rejected (never reads robots.txt) |
| `--include` / `--exclude` (regexes) | yes | rejected | rejected |
| `--include-pagespeed` | yes | rejected | rejected |
| `--timeout MIN` (default 60) | yes | rejected | rejected |

Select with `--engine auto|librecrawl|crawl4ai|fallback` (`--fallback` = `--engine fallback`). An explicit engine that is not available is an error, not a silent switch. With `auto`, LibreCrawl-only flags require LibreCrawl in local mode. Setup and flag mapping: `seo/librecrawl.md`.

| Data | LibreCrawl | Crawl4AI | Fallback |
|------|:----------:|:--------:|:--------:|
| Title, description, H1, canonical, meta robots, word count, link and image counts | yes | yes (no robots, image counts) | yes |
| Broken links with source page | yes | crawled pages only | crawled pages only |
| Redirect hops | yes | no | yes |
| Hreflang, JSON-LD, Open Graph, headings, link placement, issue detection, near-duplicates | raw exports | no | no |
| Page content as Markdown, images downloaded | no | yes | no |
| Very large crawls (SQLite queue, resume, memory limits) | yes | no | no |

## Output

```text
~/Downloads/example.com/
├── 2026-01-15_143022/
│   ├── crawl-data.csv        # one row per page (all engines)
│   ├── crawl-data.xlsx       # when openpyxl is installed and --format allows
│   ├── broken-links.csv      # url,status_code,source
│   ├── redirects.csv         # original_url,status_code,redirect_url (LibreCrawl, fallback)
│   ├── meta-issues.csv       # url,title,h1,issues
│   ├── summary.json          # counts and status codes; "backend" names the engine
│   ├── librecrawl-*.json/csv # raw LibreCrawl exports (LibreCrawl only)
│   └── content-*-md/, images/ # Crawl4AI only
└── _latest -> 2026-01-15_143022
```

**crawl-data.csv columns:** `url, status_code, status, title, title_length, meta_description, description_length, h1, h1_count, canonical, meta_robots, word_count, response_time_ms, crawl_depth, internal_links, external_links, images, images_missing_alt`.

The fallback and Crawl4AI write `broken-links.csv`, `redirects.csv` and `meta-issues.csv` only when they have rows; LibreCrawl always writes them with a header.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| SPA pages empty | `--engine librecrawl --render-js` |
| Crawl blocked | Check robots.txt; LibreCrawl: `--user-agent`, `--ignore-robots` |
| Missing pages | Increase `--depth`/`--max-urls`; check internal linking and `--include`/`--exclude` |
| LibreCrawl skipped by `auto` | `site-crawler-helper.sh status`; it must run with `LOCAL_MODE=true` at `LIBRECRAWL_URL` |
| Fallback fails on Python packages | `pip3 install aiohttp beautifulsoup4 openpyxl` |

## Integration

- **E-E-A-T**: `eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.csv`
- **PageSpeed**: `--engine librecrawl --include-pagespeed`, or `pagespeed-helper.sh` for any URL
- **Crawl4AI**: content extraction and LLM analysis, see `tools/browser/crawl4ai.md`

## Related Agents

- `seo/librecrawl.md` — LibreCrawl setup and engine details
- `seo/screaming-frog.md` — Screaming Frog SEO Spider CLI
- `seo/eeat-score.md` — E-E-A-T content quality scoring
- `tools/browser/crawl4ai.md` — AI-powered web crawling
- `tools/browser/pagespeed.md` — Performance auditing
- `seo/google-search-console.md` — Search performance data
