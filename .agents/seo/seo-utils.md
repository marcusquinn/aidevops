---
description: SEO Utils desktop app data (rank trackers, Search Console, GA4, local SEO, backlinks, log analysis) through its local stdio MCP
mode: subagent
tools:
  read: true
  write: true
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: false
  seo-utils_*: true
mcp:
  - seo-utils
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# SEO Utils MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **What**: SEO Utils is a local desktop SEO app (macOS, Windows, Linux). Its MCP server reads the app's local database (rank trackers, GSC history beyond 16 months, GA4, GMB grids, LLM rank tracker, log analysis, indexing) and runs app actions. Data stays on the user's machine.
- **Prerequisites (user)**: SEO Utils licence, the one-time MCP access add-on, a release newer than 2.5.0, and **Settings → MCP Server → Enable MCP Server** (status `Running`).
- **Activation**: Invoke `@seo-utils`; it connects the globally disabled `seo-utils` MCP on demand and disconnects after the task.
- **Launcher**: `scripts/seo-utils-mcp-launcher.sh` runs `<SEO Utils executable> mcp-stdio` (no token, no Node.js). It finds the macOS app in `/Applications` or `~/Applications`; elsewhere set `SEO_UTILS_BIN`. It refuses builds without `mcp-stdio`, because older builds ignore the argument and start the full app backend.
- **Timeout**: generated entry sets `timeout: 900000` (15 min); some actions take minutes and OpenCode's default is 60 s.
- **Credits**: lookups and several writes spend the user's DataForSEO or AI-provider credits. Local reads are free.
- **Related**: `seo/dataforseo.md` and `seo/google-search-console.md` when SEO Utils is not installed or the data is not tracked locally.

<!-- AI-CONTEXT-END -->

## Tool model

Data tools are listed directly: `list_tables`, `describe_table`, `query_database` (read-only `SELECT`, auto-limited to 1,000 rows), `query_gsc` (Search Console tables, with timezone and default filters applied), `list_workspaces`, `set_workspace`.

Everything else is an **action**, not a tool. Find one with `search_actions`, read its parameters with `describe_action` (1-10 names) before first use, then run it through the tool for its class with `{"action": "<name>", "arguments": {...}}`:

| Run tool | Class | Cost and authority |
|----------|-------|--------------------|
| `read_action` | Local data only | Free; proceed |
| `lookup_action` | External service (DataForSEO, Google, ...) | May spend credits; state scope first, confirm bulk or `google_ads` source |
| `write_action` | Create, change, delete, run, apply or send | Explicit user approval with the exact target every time |

Undeclared arguments or the wrong run tool are refused and nothing runs. Pass each argument in the type `describe_action` reports; a wrong type can be silently ignored. When a result names a follow-up action, run it through its own class tool. Use only tools and actions visible in the live session; the inventory changes between releases.

## Local data before lookups

The user's own tracked data lives in the local database. Run `describe_table` before writing SQL against a table not yet used in the session.

| Question | Correct route | Common mistake |
|----------|---------------|----------------|
| My rankings, rank tracker report | `query_database` on `organic_rank_tracker_*` | `get_organic_keywords` lookup (third-party estimate) |
| GSC trends, weak or low-CTR pages | `query_gsc` on `search_console_queries` / `search_console_pages` | Organic keyword lookup |
| Keyword cannibalisation, optimisation opportunities | `query_database` on `search_console_query_pages` (+ `search_console_query_page_mentions`) | Organic keyword lookup |
| GMB grids, reviews, LLM visibility, log analysis, automations, indexing | The matching local tables (`google_business_*`, `llm_rank_tracker_*`, `log_file_analysis_*`, `automations`, `site_urls`) | Any lookup |
| Competitor domains, fresh metrics, new keywords, backlinks for any domain | `lookup_action` (`get_organic_keywords`, `check_keyword_metrics`, `get_keyword_suggestions`, `get_backlink_summary`, `get_content_gap`, ...) | Guessing from local tables |
| What changed on a ranked page | `query_database` for two completed `organic_rank_tracker_page_html_captures`, then `compare_ranked_page_html` (read) | SERP lookup |
| Robots.txt compliance of AI bots | `get_robots_compliance` (lookup) | SQL |

Ambiguous "my backlinks" can mean tracked data or a fresh paid lookup: ask. If the user's wording is unclear about own data, phrases such as "in GSC" select local Search Console data.

Data caveats:

- `keyword_metrics.search_volume IS NULL` means "checked, no data"; `0` means zero searches. Never report NULL as 0.
- `google_business_reviews` is shared across businesses: join through `google_business_review_snapshot_reviews` against the business's latest completed snapshot, excluding `visibility_status = 'missing'`.
- Log analysis: check `log_analysis_reports.bucket_schema_version`; only upgraded reports (`>= 1`) have per-bucket AI hit columns.
- Treat ranked-page HTML diffs as correlated evidence, not proof of ranking causation.

## Workspaces

SQL sees every workspace: filter tables that have `workspace_id` by the active workspace from `list_workspaces`. Actions run in the active workspace only. `set_workspace` lasts until the MCP reconnects; the stdio connection cannot pin a workspace, so name the workspace in each request when working across clients. A named workspace that does not exist is refused, never substituted.

## Write and spend safety

Preview the exact action, target, IDs and expected cost, obtain approval, run once, then read back the result. Do not treat a request to investigate as authority to write.

- **Destructive**: `remove_organic_rank_tracker_keywords` also deletes those keywords' historical positions and insights. `delete_gmb_rank_tracker_reports` permanently removes reports, grids, snapshots and history (`delete_gmb_report_group` deletes only the group). Confirm names and IDs first.
- **Live sites and outbound**: internal-link apply/revert changes the user's live WordPress site; `send_email`, `submit_url_for_google_indexing` and automations act externally.
- **Spend**: `run_rank_tracker`, `run_gmb_rank_tracker`, LLM tracker and review-fetch runs, content structs, SERP clustering, `check_keyword_metrics` with `google_ads`, and AI outlines spend DataForSEO or AI-provider credits. After adding rank tracker keywords, ask before running the tracker.
- Workspace deletion is app-only; never look for a workaround.

## Setup and other runtimes

OpenCode: the aidevops plugin registers `seo-utils` disabled with the launcher above. An existing user-owned `seo-utils` entry (for example from SEO Utils **Connect an AI app → Add to OpenCode**) is preserved but kept disconnected and globally denied, so only `@seo-utils` uses it. Keep its `timeout` line.

Claude Code, Codex, Cursor and others: use SEO Utils **Connect an AI app**, or `configs/mcp-templates/seo-utils.json`, which points at the same launcher. The upstream skill (`seoutilsapp/seo-utils-skills`, Agent Skills format) duplicates the routing rules in this file; install it only for runtimes without this agent.

HTTP mode (`http://localhost:19515/mcp`, `Authorization: Bearer <token>`) exists for n8n, Make and remote connectors. aidevops does not use it by default. If needed, store the token with `aidevops secret set SEO_UTILS_MCP_TOKEN`, never in config or chat; rotating the token in SEO Utils breaks HTTP clients but not stdio.

## Troubleshooting

- **Launcher: not installed / set SEO_UTILS_BIN**: the app is outside the default macOS paths or the host is Windows/Linux. Copy the executable path from **Connect an AI app → Other MCP apps**.
- **Launcher: no mcp-stdio server**: update SEO Utils past 2.5.0.
- **Tools say to open SEO Utils**: the stdio server is running but the app is not; open it with the MCP server enabled, then retry.
- **Server not running**: confirm a valid licence, MCP access (Settings → MCP Server → Refresh after purchase), and that port 19515 is free.
- **Calls stop after 60 s**: the active config entry lacks `timeout`; add `"timeout": 900000`.

## Official sources

- `https://seoutils.app/mcp`
- `https://help.seoutils.app/guide/mcp-server`
- `https://github.com/seoutilsapp/seo-utils-skills`
