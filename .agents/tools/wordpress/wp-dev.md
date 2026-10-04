---
description: WordPress development & debugging - theme/plugin dev, testing, MCP Adapter, error diagnosis
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  glob: true
  grep: true
  webfetch: true
  task: true
  wordpress-mcp_*: true
  context7_*: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WordPress Development & Debugging Subagent

<!-- AI-CONTEXT-START -->

## Quick Reference

| Path | Purpose |
|------|---------|
| `~/Git/<owner>/<slug>` | Third-party plugin/theme analysis; `{slug}-fix` for patches |
| `~/Git/wordpress/mcp-adapter` | WordPress organization MCP Adapter repo |
| `~/Local Sites/` | LocalWP sites |
| `~/.config/aidevops/wordpress-sites.json` | Sites config |
| `~/.aidevops/.agent-workspace/work/wordpress/` | Working dir |
| `wp-preferred.md` | Curated plugin recommendations |

**Prerequisites**: `php -v` (>= 7.4), `composer -V`, `wp --version`, `node -v` (>= 18). Install (macOS): `brew install php@8.2 composer wp-cli node`

**New plugin**: `wp-plugin-new.md` (`/new-wp-plugin`) makes it from the latest WP Plugin Starter release; use `wp scaffold plugin` only for a bare one.

**Subagents**: `@localwp` (DB), `@wp-admin` (content), `@browser-automation` (E2E), `@code-standards` (quality). **Always use Context7** for latest WP/WP-CLI/PHP docs.

<!-- AI-CONTEXT-END -->

## Pre-change server backups

Before changing a site, store server-side backups (settings JSON, database dumps,
and copies of `wp-config.php` or `.htaccess`) in `~/backups/`, verified to be
outside the web root. Use directory mode `700` and file mode `600`. Never put
backups under `public_html`, `wp-content/uploads`, or any other web-served path;
web-server or security-plugin blocking is not a substitute for private storage.

## Composer-Based WordPress (Bedrock)

Prefer [WP Composer](https://wp-composer.com/) over WPackagist (acquired by WP Engine, March 2024). Packages: `wp-plugin/{slug}`, `wp-theme/{slug}`. Setup: `composer config repositories.wp-composer composer https://repo.wp-composer.com`. Migration: [guide](https://wp-composer.com/wp-composer-vs-wpackagist) | [script](https://github.com/roots/wp-composer/blob/main/scripts/migrate-from-wpackagist.sh)

## WordPress MCP Adapter

Requires WordPress Abilities API plugin. Repo: `~/Git/wordpress/mcp-adapter`.

**STDIO** (local): `composer require wordpress/mcp-adapter && wp plugin activate mcp-adapter` → `wp mcp-adapter serve --server=mcp-adapter-default-server --user=admin`

**HTTP** (remote): `npx @automattic/mcp-wordpress-remote` — set `WP_API_URL`, `WP_API_USERNAME`, `WP_API_PASSWORD`. Application Passwords: WP Admin > Users > Profile > "Application Passwords" → name `mcp-adapter-dev` → store via `setup-local-api-keys.sh set wp-app-password-sitename "xxxx xxxx xxxx xxxx"`. To keep the password out of runtime config, launch through `wordpress-mcp-helper.sh serve-http <url> <user> <secret-name>`, or generate a ready-to-paste config with `wordpress-mcp-helper.sh config-http <site> <url> <user> <secret-name>`.

**Plugin abilities**: plugins register their own abilities on the default server (for example Rank Math's `rank-math/*`; see `rankmath-mcp.md`).

## Testing Environments

Use an existing selected environment for routine development. The options below
are references, not setup defaults; installing or configuring a new environment,
runner, or suite requires an explicit request.

**Playground** (instant, no Docker, ephemeral): `npx @wp-playground/cli server --port=8888 --blueprint=blueprint.json`. Blueprint steps: `defineWpConfigConsts`, `installPlugin`, `enableMultisite`. [Docs](https://wordpress.github.io/wordpress-playground/blueprints). *Flaky in CI.*

**LocalWP** (5-10 min, full persistence, no Docker): Sites at `~/Local Sites/` by default; the actual paths are the `"path"` entries in `~/Library/Application Support/Local/sites.json`. WP-CLI: bundled PHAR at `/Applications/Local.app/Contents/Resources/extraResources/bin/wp-cli/wp-cli.phar` (older builds used a flat `bin/wp-cli.phar`; confirm with `ls`), run with `php <phar> --version`. Use Local's own PHP under `~/Library/Application Support/Local/lightning-services/php-*/` (match the site's PHP version, and the site's MySQL socket) rather than global PHP, which emits deprecations from WP-CLI's bundled dependencies; don't suppress them. `localhost-helper.sh list-localwp` lists registered sites read-only. Local's PHP defaults (OPcache 128 MB, `memory_limit` 256M, 2 workers) are too small for many-plugin test sites: size them first (`localwp.md` → "Site PHP resources").

**wp-env** (2-5 min, Docker, CI-ready): `wp-env start` (`npm install -g @wordpress/env`), `wp-env run cli wp plugin list`, `wp-env run tests-cli phpunit`. Config `.wp-env.json`:

```json
{
  "core": "WordPress/WordPress#6.4", "phpVersion": "8.1",
  "plugins": [".", "https://downloads.wordpress.org/plugin/query-monitor.latest-stable.zip"],
  "config": { "WP_DEBUG": true, "WP_DEBUG_LOG": true, "SCRIPT_DEBUG": true }
}
```

Multisite: add `WP_ALLOW_MULTISITE`, `MULTISITE`, `SUBDOMAIN_INSTALL`, `DOMAIN_CURRENT_SITE`, `PATH_CURRENT_SITE`, `SITE_ID_CURRENT_SITE`, `BLOG_ID_CURRENT_SITE` to `config`.

## Theme Development

**Block Theme (FSE)**: `style.css` (metadata), `theme.json` (settings), `functions.php`, `templates/` (index/single/page/archive), `parts/` (header/footer), `patterns/`.

**Template Hierarchy**: `front-page` → `home` → `index` | `single-{type}-{slug}` → `single-{type}` → `single` → `singular` | `page-{slug}` → `page-{id}` → `page` → `singular` | `archive-{type}` → `archive` | `category-{slug}` → `category-{id}` → `category` → `archive` | `search` | `404` → `index`

## Plugin Development

**Header** required: `Plugin Name`, `Description`, `Version`, `Author`, `License: GPL-2.0+`, `Text Domain`, `Requires at least: 6.0`, `Requires PHP: 7.4`. Hooks/filters API → use Context7 for current reference.

## Plugin & Theme Analysis Workflow

Use `~/Git/<owner>/<slug>` for third-party repositories and `~/Git/<slug>` for
repositories owned by a configured personal account. Suffixes: `{slug}`
(analysis/fork), `{slug}-addon` (companion for pro/closed), `{slug}-fix`
(update-safe patches), `{slug}-child` (child theme).

```bash
mkdir -p ~/Git/developer && git clone https://github.com/developer/plugin-slug.git ~/Git/developer/plugin-slug
# Pro/local-only: import to an explicit registered path under ~/Git.
rg "add_action|add_filter" --type php .
ln -s ~/Git/developer/plugin-slug "~/Local Sites/test-site/app/public/wp-content/plugins/"
```

**Patching pro/closed plugins** — create `{slug}-fix` companion that survives updates. Guard with `class_exists`/`function_exists`. Use priority > 10. Document issue URL and affected versions. Version-gate: `version_compare(ORIGINAL_PLUGIN_VERSION, '2.4.0', '<')`.

```php
<?php
/** Plugin Name: Plugin Slug Fix; Requires Plugins: plugin-slug */
add_action('plugins_loaded', 'plugin_slug_fix_init', 20);
function plugin_slug_fix_init() {
    if (!class_exists('Original_Plugin_Class')) { return; }
    remove_action('init', 'original_problematic_function');
    add_action('init', 'fixed_function');
}
add_filter('original_filter', 'my_fixed_filter', 999);
function my_fixed_filter($value) { return $modified_value; }
```

**Sync to LocalWP**: a LocalWP site is **shared by every parallel session/worktree** working on the same plugin or theme — a plain `rsync --delete` lets a stale worktree silently overwrite another session's merged work. Merge the default branch into your worktree first, then use the freshness-checked helper instead of a raw `rsync`:

```bash
local-site-sync-helper.sh sync --src ~/Git/_worktrees/plugin-slug-feature/ \
  --dest "~/Local Sites/site-name/app/public/wp-content/plugins/plugin-slug/" \
  --exclude-from .distignore
local-site-sync-helper.sh status --dest "~/Local Sites/site-name/app/public/wp-content/plugins/plugin-slug/"
```

It refuses to sync when the worktree's `HEAD` doesn't contain `origin/<default-branch>` (use `--force` only when intentional), warns if another worktree synced to the same destination in the last 30 minutes, and writes a stamp (source worktree, branch, HEAD SHA, dirty flag, time) next to the destination so any session can answer "which branch is on the site, and who put it there?" with `status`. After merging to the default branch, run `status` before telling the user to look. Prefer a throwaway per-worktree site (e.g. a Docker `wordpress` container on a unique port) for in-progress verification; keep the shared LocalWP site for showing the user the merged result.

## Debugging

**Debug constants** (`wp-config.php`): `WP_DEBUG=true`, `WP_DEBUG_LOG=true` (→ `wp-content/debug.log`), `WP_DEBUG_DISPLAY=false`, `SCRIPT_DEBUG=true`, `SAVEQUERIES=true`. Logs: `~/Local Sites/site-name/app/public/wp-content/debug.log` (LocalWP) | `wp-env run cli tail -f /var/www/html/wp-content/debug.log` (wp-env).

**Query Monitor**: `wp plugin install query-monitor --activate` — DB queries, PHP errors, HTTP requests, hooks, template hierarchy, memory.

**Error diagnosis flow**: Enable `WP_DEBUG` → check `debug.log` → Query Monitor → `@localwp` for DB → `wp hook list` → `wp profile` or Code Profiler Pro.

## WP-CLI Quick Reference

**Scaffold**: `wp scaffold {theme|child-theme|plugin|post-type|block} name [--activate]`. **DB**: `wp db {export|import} backup.sql`, `wp search-replace 'old' 'new' --dry-run`, `wp db optimize && wp db check`. **Dev**: `wp shell`, `wp eval '...'`, `wp {post|user} generate --count=N`, `wp cache flush && wp transient delete --all`.

## Testing

Run already configured checks when applicable: **PHPUnit** `wp-env run tests-cli phpunit` or `vendor/bin/phpunit`; **E2E** `npx --no-install playwright test` or `npx --no-install cypress run`; **Security** `./.agents/scripts/secretlint-helper.sh scan`. For routine feature/fix work, verify first through the real LocalWP/wp-env flow and `debug.log`. Do not install PHPUnit, Playwright, Cypress, or new test infrastructure without explicit user approval.

**Release checklist**: single + multisite, min/latest PHP/WP, configured/required PHPUnit and E2E checks passing, no PHP errors/warnings in debug log, no JS console errors, activation/deactivation/uninstall exercised, security + code quality passed. Do not add missing test infrastructure solely for release verification without approval.

Plugin release builds, WordPress.org preflight, Plugin Check and submission: `tools/wordpress/wp-plugin-release.md` and `wp-plugin-release-helper.sh`.
