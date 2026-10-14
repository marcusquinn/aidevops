---
description: LibreCrawl self-hosted SEO crawler - local-mode setup and site-crawler engine
mode: subagent
tools:
  read: true
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# LibreCrawl

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Free, self-hosted SEO crawler (Screaming Frog-style) with JavaScript rendering, robots.txt control, include/exclude regexes, PageSpeed, issue detection and JSON/CSV exports. It keeps the crawl queue in SQLite, so large crawls survive a restart and can be resumed from its dashboard.
- **License**: MIT. **Source**: [PhialsBasement/LibreCrawl](https://github.com/PhialsBasement/LibreCrawl) (no tagged releases; the helper was written against `main` at `05a1372de833`).
- **Helper**: `site-crawler-helper.sh crawl <url> --engine librecrawl` (also picked by `--engine auto` when LibreCrawl answers in local mode).
- **Server URL**: `LIBRECRAWL_URL`, default `http://127.0.0.1:5000`.
- **Check**: `site-crawler-helper.sh status` reports whether LibreCrawl is reachable and in local mode.
- **Safety**: local mode gives **every visitor admin rights**. Bind it to `127.0.0.1` only. The helper connects to a running server; it never starts or exposes containers.

<!-- AI-CONTEXT-END -->

## Run in local mode

```bash
git clone https://github.com/PhialsBasement/LibreCrawl.git
cd LibreCrawl
LOCAL_MODE=true docker compose up -d --build
site-crawler-helper.sh status
```

- The compose file publishes `${HOST_BINDING:-127.0.0.1}:${EXTERNAL_PORT:-5000}`. Leave `HOST_BINDING` unset. Never combine `LOCAL_MODE=true` with `HOST_BINDING=0.0.0.0`, a LAN IP, a tunnel or a reverse proxy: local mode has no authentication.
- Port 5000 is also used by macOS AirPlay Receiver. If it is taken, pick another port and point the helper at it:

  ```bash
  LOCAL_MODE=true EXTERNAL_PORT=5055 docker compose up -d --build
  export LIBRECRAWL_URL=http://127.0.0.1:5055
  ```

- Crawl history and the user database persist in `./data` in the checkout.
- For a shared or remote server, run LibreCrawl **without** local mode behind its own accounts. The helper does not use such a server: a guest there gets 3 crawls a day and no JavaScript rendering, so `--engine librecrawl` stops with guidance instead of half-working.

## Update

```bash
cd LibreCrawl   # your checkout
git pull
LOCAL_MODE=true docker compose up -d --build
site-crawler-helper.sh status
```

LibreCrawl has no versioned API. After an update, run a small crawl (`--max-urls 20`) and check that `summary.json` has `"complete": true`.

## How the helper uses it

1. Signs in as a guest (`POST /api/guest-login`) with a cookie jar in a private `mktemp -d` directory that is removed on exit, then checks `GET /api/user/info`. Local mode gives guests the admin tier; any other tier stops the crawl.
2. Applies settings for that session only (`POST /api/save_settings`, then `/api/update_crawler_settings`). Your dashboard settings are not changed. Unset options use LibreCrawl's defaults (1 s crawl delay, 5 workers, sitemap discovery on).
3. Starts the crawl (`POST /api/start_crawl`) and polls `GET /api/crawl_status` every 2 s. On `--timeout` (default 60 min) or Ctrl-C it calls `POST /api/stop_crawl`; a timeout still exports partial results and exits non-zero.
4. Exports through `GET /api/export_stream` and writes the shared layout.

| Helper flag | LibreCrawl setting |
|-------------|--------------------|
| `--depth N` (1–10) | `maxDepth` |
| `--max-urls N` | `maxUrls` |
| `--render-js` | `enableJavaScript` (Chromium via Playwright) |
| `--user-agent UA` | `userAgent` and `jsUserAgent` |
| `--ignore-robots` | `respectRobotsTxt=false` |
| `--include a,b` / `--exclude a,b` | `includePatterns` / `excludePatterns` (Python regexes matched anywhere in the URL; repeat the flag or separate with commas) |
| `--include-pagespeed` | `enablePageSpeed`, plus `googleApiKey` from `GOOGLE_API_KEY` in the environment or `aidevops secret get GOOGLE_API_KEY`. The key goes in a request body file, never on a command line. LibreCrawl tests the home page and two section pages. |
| `--timeout MIN` | Helper-side limit |

## Output

Under `~/Downloads/{domain}/{timestamp}/` (`_latest` points at the newest crawl):

| File | Content |
|------|---------|
| `crawl-data.csv` | Internal HTML pages, same columns as the other engines (`h1_count` is 0 or 1 because LibreCrawl keeps the first H1) |
| `broken-links.csv` | `url,status_code,source`: link targets with 4XX/5XX or no response (`0`), plus broken pages with no linking source (`direct`) |
| `redirects.csv` | `original_url,status_code,redirect_url`, one row per redirect hop |
| `meta-issues.csv` | Missing or long title/description, missing H1 on 2XX pages |
| `summary.json` | Counts, status codes, LibreCrawl issue counts by type, `backend: "librecrawl"`, `complete` |
| `librecrawl-urls.json` | Raw URL export (titles, headings, canonical, robots, hreflang, JSON-LD, images, redirects, timing) |
| `librecrawl-links.csv` | `source_url,target_url,anchor_text,is_internal,target_domain,target_status,placement` (`placement`: navigation, footer, body, image) |
| `librecrawl-issues.csv` | LibreCrawl issue detector output, including near-duplicate content |
| `librecrawl-pagespeed.json` | PageSpeed results, when `--include-pagespeed` returned any |

`crawl-data.xlsx` is also written when `--format` is not `csv` and Python `openpyxl` is available. The raw `librecrawl-*` files are meant for import by other tools unchanged.

## Related

- `seo/site-crawler.md`: engines, commands and capability table
- `seo/screaming-frog.md`: paid desktop crawler CLI
- `tools/browser/pagespeed.md`: standalone PageSpeed/Lighthouse runs
