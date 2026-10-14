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
- **Engine choice**: `--engine auto` (default) uses LibreCrawl in local mode or with configured account credentials at `LIBRECRAWL_URL`, else Crawl4AI at `http://localhost:11235`, else the fallback

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
| `push-seoprostats <dir> --site <hostname>` | Import one saved crawl into SEO Pro Stats 1.11.0+; SSH when inventory-ready, else REST |

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
| `--push-seoprostats HOST` (after successful crawl) | yes | yes | yes |

Select with `--engine auto|librecrawl|crawl4ai|fallback` (`--fallback` = `--engine fallback`). An explicit engine that is not available is an error, not a silent switch. With `auto`, LibreCrawl-only flags require a usable LibreCrawl session (local mode or configured account). Setup and flag mapping: `seo/librecrawl.md`.

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
| LibreCrawl skipped by `auto` | `site-crawler-helper.sh status`; use loopback local mode or configure `LIBRECRAWL_USERNAME` / `LIBRECRAWL_PASSWORD` for the shared server |
| Fallback fails on Python packages | `pip3 install aiohttp beautifulsoup4 openpyxl` |

## Integration

### Push a crawl to SEO Pro Stats

Reference: `wpallstars/seoprostats`, `docs/seo-loop-recipes.md` → **A crawl for the loop**, and the plugin's crawl import REST and WP-CLI contracts (introduced in 1.11.0). Install and activate SEO Pro Stats 1.11.0 or later on the destination WordPress site first.

```bash
site-crawler-helper.sh crawl https://example.com --engine librecrawl --push-seoprostats example.com
site-crawler-helper.sh push-seoprostats ~/Downloads/example.com/_latest --site example.com
# Override automatic transport selection:
site-crawler-helper.sh push-seoprostats ~/Downloads/example.com/_latest --site example.com --transport rest --timeout 600
```

The site is a hostname only, without a scheme, path or port. `--timeout` on **push-seoprostats** is seconds (default 600); on **crawl** it remains the LibreCrawl timeout in minutes. The post-crawl flag uses the default automatic push transport. Failed or partial crawls are not automatically uploaded; a failed push returns non-zero and preserves the saved reports for retry.

The upload prefers `librecrawl-urls.json` and, when available, `librecrawl-links.csv`, retaining fields the plugin maps natively. Otherwise it uploads `crawl-data.csv` and any existing `broken-links.csv` / `redirects.csv`. It does not mix raw and mapped exports or upload unrelated report files. Files over **52,428,800 bytes (50 MiB)** are refused before either transport writes anything; host/PHP limits can be lower. Importing replaces the plugin's previous crawl findings for the imported kinds, not page content. Re-importing the same files does not change their findings.

**SSH / WP-CLI (preferred):** `site-context-helper.sh readiness <hostname>` must return `readiness: "ready"` with `hosting.ssh_host`, `ssh_user`, `ssh_port` (default 22) and an absolute `deployment_path`. Uses the normal SSH agent/key and host-key verification, non-interactively (`BatchMode=yes`); no passwords or host-key bypasses are injected. The helper creates a private remote temporary directory, copies the selected files with `scp`, runs `wp seoprostats crawl import <files> --path=<deployment_path>`, prints WP-CLI's import ID and counts, and removes the directory on exit. `wp` must be on the remote PATH. SSH/import failure is reported, not silently retried through REST. `--transport ssh` refuses inventory gaps.

**REST (when SSH is not ready, or `--transport rest`):** provision a WordPress user with `manage_options` and create an Application Password in its profile. Store the username and password with `aidevops secret set` (interactive secure input, never as command arguments). The suffix is the uppercase hostname with dots and hyphens replaced by underscores:

```bash
# example.com -> EXAMPLE_COM; www.example-site.com -> WWW_EXAMPLE_SITE_COM
aidevops secret set SEOPROSTATS_USERNAME_EXAMPLE_COM
aidevops secret set SEOPROSTATS_APP_PASSWORD_EXAMPLE_COM
```

Same-named environment variables override stored secrets. The helper uses verified HTTPS and a private curl authentication file, never a password in argv or logs; it does not follow redirects. It posts multipart `files[]` to `/wp-json/seoprostats/v1/crawl/import`, then polls GET on the same route. Each poll advances the import; job IDs must remain equal. It reports the ID and page/link/skipped/change counts when `done`, and exits non-zero on `failed`, `error`, HTTP/authentication errors, unexpected responses or timeout. A timeout does not cancel the server job: inspect the plugin before retrying to avoid a concurrent import. Local credentials and response files are removed on exit. Do not enable shell tracing around secrets.

Verify the result with `wp seoprostats crawl --format=json` on the destination (the default report lists findings), or the plugin's Crawl screen. Scheduling remains the plugin's responsibility; this command performs one explicit import.

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
