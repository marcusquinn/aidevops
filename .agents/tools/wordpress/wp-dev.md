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

# WordPress Development & Debugging Subagent

<!-- AI-CONTEXT-START -->

## Quick Reference

| Path | Purpose |
|------|---------|
| `~/Git/wordpress/{slug}` | Plugin/theme analysis; `{slug}-fix` for patches |
| `~/Git/wordpress/mcp-adapter` | MCP Adapter repo |
| `~/Local Sites/` | LocalWP sites |
| `~/.config/aidevops/wordpress-sites.json` | Sites config |
| `~/.aidevops/.agent-workspace/work/wordpress/` | Working dir |
| `wp-preferred.md` | Curated plugin recommendations |

**Prerequisites**: `php -v` (>= 7.4), `composer -V`, `wp --version`, `node -v` (>= 18)

**Install** (macOS): `brew install php@8.2 composer wp-cli node`

**Subagents**: `@localwp` (DB), `@wp-admin` (content), `@browser-automation` (E2E), `@code-standards` (quality). **Always use Context7** for latest WP/WP-CLI/PHP docs.

<!-- AI-CONTEXT-END -->

## Composer-Based WordPress (Bedrock)

Prefer [WP Composer](https://wp-composer.com/) over WPackagist (acquired by WP Engine, March 2024). Package naming: `wp-plugin/{slug}`, `wp-theme/{slug}`.

```bash
composer config repositories.wp-composer composer https://repo.wp-composer.com
```

Migration: [guide](https://wp-composer.com/wp-composer-vs-wpackagist) | [script](https://github.com/roots/wp-composer/blob/main/scripts/migrate-from-wpackagist.sh)

## WordPress MCP Adapter

Requires WordPress Abilities API plugin. Repo: `~/git/wordpress/mcp-adapter`.

**STDIO** (local):

```bash
composer require wordpress/mcp-adapter && wp plugin activate mcp-adapter
wp mcp-adapter serve --server=mcp-adapter-default-server --user=admin
```

**HTTP** (remote): `npx @automattic/mcp-wordpress-remote` — set `WP_API_URL`, `WP_API_USERNAME`, `WP_API_PASSWORD`. Application Passwords: WP Admin > Users > Profile > "Application Passwords" > name `mcp-adapter-dev` > store via `setup-local-api-keys.sh set wp-app-password-sitename "xxxx xxxx xxxx xxxx"`

## Testing Environments

| Feature | Playground | LocalWP | wp-env |
|---------|------------|---------|--------|
| Setup Time | Instant | 5-10 min | 2-5 min |
| Persistence | None | Full | Partial |
| Docker Required | No | No | Yes |
| GitHub Actions | Works* | N/A | Works |
| Best For | Quick testing | Full dev | CI/Testing |

*Playground may be flaky in CI. LocalWP sites: `~/Local Sites/`. WP-CLI: `/Applications/Local.app/Contents/Resources/extraResources/bin/wp-cli.phar`

**Playground:**

```bash
npx @wp-playground/cli server --port=8888 --blueprint=blueprint.json
```

Blueprint schema: `https://playground.wordpress.net/blueprint-schema.json`. Key steps: `defineWpConfigConsts` (WP_DEBUG), `installPlugin`, `enableMultisite`. Docs: [Blueprints](https://wordpress.github.io/wordpress-playground/blueprints).

**wp-env** (Docker/CI):

```bash
wp-env start   # npm install -g @wordpress/env
wp-env run cli wp plugin list
wp-env run tests-cli phpunit
```

`.wp-env.json`:

```json
{
  "core": "WordPress/WordPress#6.4",
  "phpVersion": "8.1",
  "plugins": [".", "https://downloads.wordpress.org/plugin/query-monitor.latest-stable.zip"],
  "config": { "WP_DEBUG": true, "WP_DEBUG_LOG": true, "SCRIPT_DEBUG": true }
}
```

Multisite: add `WP_ALLOW_MULTISITE`, `MULTISITE`, `SUBDOMAIN_INSTALL`, `DOMAIN_CURRENT_SITE`, `PATH_CURRENT_SITE`, `SITE_ID_CURRENT_SITE`, `BLOG_ID_CURRENT_SITE` to `config`.

## Theme Development

**Block Theme (FSE)**: `style.css` (metadata), `theme.json` (settings), `functions.php`, `templates/` (index/single/page/archive), `parts/` (header/footer), `patterns/`.

**Template Hierarchy**: `front-page` → `home` → `index` | `single-{type}-{slug}` → `single-{type}` → `single` → `singular` | `page-{slug}` → `page-{id}` → `page` → `singular` | `archive-{type}` → `archive` | `category-{slug}` → `category-{id}` → `category` → `archive` | `search` | `404` → `index`

## Plugin Development

**Plugin Header** required fields: `Plugin Name`, `Description`, `Version`, `Author`, `License: GPL-2.0+`, `Text Domain`, `Requires at least: 6.0`, `Requires PHP: 7.4`.

### Hooks & Filters

```php
add_action('init', 'my_plugin_init');
add_action('wp_enqueue_scripts', 'my_plugin_enqueue');
add_action('save_post', 'my_plugin_save', 10, 3);
add_filter('the_content', 'my_plugin_filter_content');
do_action('my_plugin_before_output');
$value = apply_filters('my_plugin_value', $default);
```

## Plugin & Theme Analysis Workflow

All plugin/theme work lives under `~/Git/wordpress/`:

| Suffix | Purpose | Example |
|--------|---------|---------|
| `{slug}` | Clone for analysis or open-source fork | `readabler`, `flavor` |
| `{slug}-addon` | Custom addon for pro/closed plugins | `kadence-blocks-addon` |
| `{slug}-fix` | Patches that survive updates | `media-file-renamer-fix` |
| `{slug}-child` | Child theme customizations | `kadence-child` |

```bash
cd ~/Git/wordpress && git clone https://github.com/developer/plugin-slug.git
# Pro plugins: unzip ~/Downloads/plugin-name.zip -d ~/Git/wordpress/ && git init && git add . && git commit -m "Initial import v1.0.0"
rg "add_action|add_filter" --type php .
ln -s ~/Git/wordpress/plugin-slug "~/Local Sites/test-site/app/public/wp-content/plugins/"
```

### Patching Pro/Closed Plugins

Create a companion plugin (`{slug}-fix`) that survives updates. Guard with `class_exists`/`function_exists`. Use priority > 10. Document issue URL and affected versions. Version-gate: `version_compare(ORIGINAL_PLUGIN_VERSION, '2.4.0', '<')`.

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

### Syncing with LocalWP

```bash
rsync -av --delete --exclude='.git' --exclude='node_modules' --exclude='vendor' \
    ~/Git/wordpress/plugin-slug/ \
    "~/Local Sites/site-name/app/public/wp-content/plugins/plugin-slug/"
```

## Debugging

**Debug constants** in `wp-config.php`: `WP_DEBUG=true`, `WP_DEBUG_LOG=true` (→ `wp-content/debug.log`), `WP_DEBUG_DISPLAY=false`, `SCRIPT_DEBUG=true`, `SAVEQUERIES=true`.

Logs: `~/Local Sites/site-name/app/public/wp-content/debug.log` (LocalWP) | `wp-env run cli tail -f /var/www/html/wp-content/debug.log` (wp-env)

**Query Monitor**: `wp plugin install query-monitor --activate` — shows DB queries, PHP errors, HTTP requests, hooks, template hierarchy, memory.

**OpenCode PHP LSP (Intelephense)**: If WordPress symbols are unresolved (`add_action`, `WP_Query`), configure `~/.config/opencode/config.json` with `lsp.intelephense` using local binary path, `extensions: ["php"]`, and `intelephense.stubs` including `"wordpress"`. If diagnostics persist, clear/rebuild cache. Do not suggest Claude-specific commands (e.g., `/lsp-restart`) in OpenCode sessions.

**Error Diagnosis**: Enable `WP_DEBUG` → check `debug.log` → Query Monitor → `@localwp` for DB → `wp hook list` → `wp profile` or Code Profiler Pro.

## WP-CLI Commands

```bash
# Scaffold
wp scaffold theme theme-name --theme_name="Theme Name" --activate
wp scaffold child-theme child-name --parent_theme=parent-name --activate
wp scaffold plugin plugin-name && wp scaffold post-type cpt-name --plugin=plugin-name
wp scaffold block block-name --plugin=plugin-name

# Database
wp db export backup.sql && wp db import backup.sql
wp search-replace 'old.domain.com' 'new.domain.com' --dry-run
wp db optimize && wp db check

# Development
wp shell && wp eval 'echo get_option("siteurl");'
wp post generate --count=10 && wp user generate --count=5
wp cache flush && wp transient delete --all
```

## Testing

```bash
# PHPUnit
wp-env run tests-cli phpunit
composer require --dev phpunit/phpunit wp-phpunit/wp-phpunit && vendor/bin/phpunit

# E2E
npx playwright test              # npm install -D @playwright/test
npx cypress run                  # npm install -D cypress

# Security
./.agents/scripts/secretlint-helper.sh scan
```

### Release Checklist

- [ ] Tested on single site and multisite
- [ ] Tested with minimum and latest PHP/WordPress versions
- [ ] PHPUnit and E2E tests passing
- [ ] No PHP errors/warnings in debug log, no JS console errors
- [ ] Tested activation/deactivation/uninstall
- [ ] Security scan completed
- [ ] Code quality checks passed

## Resources

- [WordPress Playground](https://wordpress.github.io/wordpress-playground/) + [Blueprints](https://wordpress.github.io/wordpress-playground/blueprints)
- [LocalWP Docs](https://localwp.com/help-docs/) | [@wordpress/env Docs](https://developer.wordpress.org/block-editor/reference-guides/packages/packages-env/)
- [PHPUnit for WordPress](https://make.wordpress.org/core/handbook/testing/automated-testing/phpunit/)
- [WordPress MCP Adapter](https://github.com/WordPress/mcp-adapter) | [WP-CLI Commands](https://developer.wordpress.org/cli/commands/)
- [WP Composer](https://wp-composer.com/) | [Bedrock](https://roots.io/bedrock/)
