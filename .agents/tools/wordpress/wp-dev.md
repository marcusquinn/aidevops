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

**Subagents**: `@localwp` (DB), `@wp-admin` (content), `@browser-automation` (E2E), `@code-standards` (quality). **Always use Context7** for latest WP/WP-CLI/PHP docs.

<!-- AI-CONTEXT-END -->

## Installation (macOS)

```bash
brew install php@8.2 composer wp-cli node
```

## Composer-Based WordPress (Bedrock)

For Bedrock-style projects, use [WP Composer](https://wp-composer.com/) as the Composer repository (preferred over WPackagist, acquired by WP Engine March 2024). Package naming: `wp-plugin/{slug}`, `wp-theme/{slug}`. Not applicable to traditional WP-CLI/admin-managed installations.

```bash
composer config repositories.wp-composer composer https://repo.wp-composer.com
```

Migration: [guide](https://wp-composer.com/wp-composer-vs-wpackagist) | [script](https://github.com/roots/wp-composer/blob/main/scripts/migrate-from-wpackagist.sh)

## WordPress MCP Adapter

Official AI interaction with WordPress sites. Requires WordPress Abilities API plugin. Repo: `~/git/wordpress/mcp-adapter` (update: `cd ~/git/wordpress/mcp-adapter && git pull`).

**STDIO** (local):

```bash
cd /path/to/wordpress
composer require wordpress/mcp-adapter
wp plugin activate mcp-adapter
wp mcp-adapter serve --server=mcp-adapter-default-server --user=admin
```

**HTTP** (remote):

```bash
npx @automattic/mcp-wordpress-remote

export WP_API_URL="https://your-site.com/wp-json/mcp/mcp-adapter-default-server"
export WP_API_USERNAME="your-username"
export WP_API_PASSWORD="your-application-password"
```

**Application Passwords** (for HTTP): WordPress Admin > Users > Profile > "Application Passwords" > name `mcp-adapter-dev` > store via `setup-local-api-keys.sh set wp-app-password-sitename "xxxx xxxx xxxx xxxx"`

## Testing Environments

| Feature | Playground | LocalWP | wp-env |
|---------|------------|---------|--------|
| Setup Time | Instant | 5-10 min | 2-5 min |
| Persistence | None | Full | Partial |
| PHP Versions | Limited | Many | Configurable |
| Database | In-memory | MySQL | MySQL |
| Docker Required | No | No | Yes |
| GitHub Actions | Works* | N/A | Works |
| Best For | Quick testing | Full dev | CI/Testing |

*Playground may be flaky in CI environments

### WordPress Playground

```bash
npx @wp-playground/cli server --port=8888 --blueprint=blueprint.json
```

**Blueprint** (`blueprint.json`):

```json
{
  "$schema": "https://playground.wordpress.net/blueprint-schema.json",
  "landingPage": "/wp-admin/",
  "login": true,
  "features": { "networking": true },
  "phpExtensionBundles": ["kitchen-sink"],
  "steps": [
    {
      "step": "defineWpConfigConsts",
      "consts": {
        "WP_DEBUG": true,
        "WP_DEBUG_LOG": true,
        "WP_DEBUG_DISPLAY": false,
        "SCRIPT_DEBUG": true
      }
    },
    {
      "step": "installPlugin",
      "pluginZipFile": {
        "resource": "url",
        "url": "https://downloads.wordpress.org/plugin/query-monitor.latest-stable.zip"
      }
    }
  ]
}
```

**Multisite Blueprint**:

```json
{
  "$schema": "https://playground.wordpress.net/blueprint-schema.json",
  "landingPage": "/wp-admin/network/",
  "login": true,
  "steps": [
    { "step": "enableMultisite" },
    {
      "step": "installPlugin",
      "pluginZipFile": { "resource": "directory", "path": "." },
      "options": { "activate": true, "networkActivate": true }
    }
  ]
}
```

### LocalWP

Sites: `~/Local Sites/`. WP-CLI path: `/Applications/Local.app/Contents/Resources/extraResources/bin/wp-cli.phar`

```bash
cd "~/Local Sites/site-name/app/public"
wp plugin list
```

### wp-env (Docker/CI)

```bash
wp-env start                          # npm install -g @wordpress/env
wp-env run cli wp plugin list
wp-env run tests-cli phpunit
```

**Configuration** (`.wp-env.json`):

```json
{
  "core": "WordPress/WordPress#6.4",
  "phpVersion": "8.1",
  "plugins": [".", "https://downloads.wordpress.org/plugin/query-monitor.latest-stable.zip"],
  "config": { "WP_DEBUG": true, "WP_DEBUG_LOG": true, "SCRIPT_DEBUG": true }
}
```

**Multisite** — add to `config`:

```json
{
  "WP_ALLOW_MULTISITE": true,
  "MULTISITE": true,
  "SUBDOMAIN_INSTALL": false,
  "DOMAIN_CURRENT_SITE": "localhost",
  "PATH_CURRENT_SITE": "/",
  "SITE_ID_CURRENT_SITE": 1,
  "BLOG_ID_CURRENT_SITE": 1
}
```

## Theme Development

### Block Theme Structure (FSE)

```text
theme-name/
├── style.css              # Theme metadata
├── theme.json             # Global settings
├── functions.php          # Theme functions
├── templates/             # Block templates (index, single, page, archive)
├── parts/                 # Template parts (header, footer)
└── patterns/              # Block patterns
```

### Template Hierarchy

```text
is_front_page()  → front-page.html → home.html → index.html
is_single()      → single-{post-type}-{slug}.html → single-{post-type}.html → single.html → singular.html → index.html
is_page()        → page-{slug}.html → page-{id}.html → page.html → singular.html → index.html
is_archive()     → archive-{post-type}.html → archive.html → index.html
is_category()    → category-{slug}.html → category-{id}.html → category.html → archive.html → index.html
is_search()      → search.html → index.html
is_404()         → 404.html → index.html
```

## Plugin Development

### Plugin Header

```php
<?php
/**
 * Plugin Name: My Plugin
 * Description: Plugin description
 * Version: 1.0.0
 * Author: Your Name
 * License: GPL-2.0+
 * Text Domain: my-plugin
 * Requires at least: 6.0
 * Requires PHP: 7.4
 */
```

### Hooks & Filters

```php
// Actions (do something)
add_action('init', 'my_plugin_init');
add_action('wp_enqueue_scripts', 'my_plugin_enqueue');
add_action('save_post', 'my_plugin_save', 10, 3);

// Filters (modify something)
add_filter('the_content', 'my_plugin_filter_content');
add_filter('wp_title', 'my_plugin_filter_title', 10, 2);

// Custom hooks
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

### Analyzing a Plugin/Theme

```bash
cd ~/Git/wordpress
git clone https://github.com/developer/plugin-slug.git
# Or extract from zip (for pro plugins):
unzip ~/Downloads/plugin-name.zip -d ~/Git/wordpress/
cd ~/Git/wordpress/plugin-slug && git init && git add . && git commit -m "Initial import v1.0.0"

rg "add_action|add_filter" --type php .

# Symlink into LocalWP for testing
ln -s ~/Git/wordpress/plugin-slug "~/Local Sites/test-site/app/public/wp-content/plugins/"
```

### Patching Pro/Closed Plugins

Create a companion plugin that survives updates:

```php
<?php
/**
 * Plugin Name: Plugin Slug Fix
 * Description: Patches for Plugin Slug that survive updates
 * Version: 1.0.0
 * Requires Plugins: plugin-slug
 */

add_action('plugins_loaded', 'plugin_slug_fix_init', 20);

function plugin_slug_fix_init() {
    if (!class_exists('Original_Plugin_Class')) { return; }
    remove_action('init', 'original_problematic_function');
    add_action('init', 'fixed_function');
}

function fixed_function() { /* fixed implementation */ }

// Override a filter with higher priority
add_filter('original_filter', 'my_fixed_filter', 999);
function my_fixed_filter($value) { return $modified_value; }
```

**Best practices**: (1) Guard with `class_exists`/`function_exists`. (2) Use priority > 10 to run after original. (3) Document the issue URL and affected versions. (4) Version-gate if needed: `version_compare(ORIGINAL_PLUGIN_VERSION, '2.4.0', '<')`.

### Syncing with LocalWP

```bash
rsync -av --delete --exclude='.git' --exclude='node_modules' --exclude='vendor' \
    ~/Git/wordpress/plugin-slug/ \
    "~/Local Sites/site-name/app/public/wp-content/plugins/plugin-slug/"
```

## Debugging

### Debug Constants

```php
// wp-config.php
define('WP_DEBUG', true);
define('WP_DEBUG_LOG', true);      // Log to wp-content/debug.log
define('WP_DEBUG_DISPLAY', false); // Don't show on screen
define('SCRIPT_DEBUG', true);      // Use non-minified scripts
define('SAVEQUERIES', true);       // Log database queries
```

**Log locations**: `~/Local Sites/site-name/app/public/wp-content/debug.log` (LocalWP) or `wp-env run cli tail -f /var/www/html/wp-content/debug.log` (wp-env)

### Query Monitor

Essential debugging plugin — shows DB queries, PHP errors, HTTP requests, hooks, template hierarchy, memory:

```bash
wp plugin install query-monitor --activate
```

### OpenCode PHP LSP (Intelephense + WordPress)

If WordPress symbols are unresolved in OpenCode (`add_action`, `WP_Query`, globals), configure `~/.config/opencode/config.json` with Intelephense + WordPress stubs, then restart the LSP process:

```json
{
  "lsp": {
    "intelephense": {
      "command": [
        "/home/USER/.local/share/opencode/bin/node_modules/.bin/intelephense",
        "--stdio"
      ],
      "extensions": ["php"],
      "initialization": {
        "intelephense.stubs": [
          "Core", "json", "mbstring", "mysqli", "PDO", "SPL", "standard", "wordpress"
        ]
      }
    }
  }
}
```

Use your local Intelephense path (not `/home/USER/...`). If diagnostics persist, clear/rebuild cache. Do not suggest Claude-specific commands (e.g., `/lsp-restart`) in OpenCode sessions.

### Error Diagnosis Workflow

1. Enable `WP_DEBUG` constants → check `debug.log` → use Query Monitor
2. Inspect database via `@localwp` → check hooks with `wp hook list`
3. Profile performance with `wp profile` or Code Profiler Pro

## WP-CLI Commands

```bash
# Scaffold
wp scaffold theme theme-name --theme_name="Theme Name" --activate
wp scaffold child-theme child-name --parent_theme=parent-name --activate
wp scaffold plugin plugin-name
wp scaffold post-type cpt-name --plugin=plugin-name
wp scaffold block block-name --plugin=plugin-name

# Database
wp db export backup.sql && wp db import backup.sql
wp search-replace 'old.domain.com' 'new.domain.com' --dry-run
wp db optimize && wp db check

# Development
wp shell                          # Interactive PHP
wp eval 'echo get_option("siteurl");'
wp post generate --count=10 && wp user generate --count=5
wp cache flush && wp transient delete --all
```

## PHPUnit Testing

```bash
wp-env run tests-cli phpunit                                    # wp-env
composer require --dev phpunit/phpunit wp-phpunit/wp-phpunit    # Composer
vendor/bin/phpunit
```

### Test File Structure

```php
<?php
class Test_My_Plugin extends WP_UnitTestCase {

    public function test_post_creation() {
        $post_id = $this->factory->post->create([
            'post_title'  => 'Test Post',
            'post_status' => 'publish',
        ]);
        $this->assertIsInt($post_id);
        $this->assertEquals('Test Post', get_the_title($post_id));
    }
}
```

### phpunit.xml

```xml
<?xml version="1.0"?>
<phpunit bootstrap="tests/bootstrap.php" backupGlobals="false" colors="true">
    <testsuites>
        <testsuite name="My Plugin Test Suite">
            <directory suffix=".php">./tests/</directory>
        </testsuite>
    </testsuites>
</phpunit>
```

## E2E & Security

```bash
# Playwright
npx playwright test              # npm install -D @playwright/test
npx playwright test --ui

# Cypress
npx cypress run                  # npm install -D cypress
npx cypress open

# Security scanning
./.agents/scripts/secretlint-helper.sh scan
grep -r "password\|api_key\|secret" --include="*.php" .
```

## Testing Checklist

Before releasing a plugin/theme:

- [ ] Tested on single site and multisite
- [ ] Tested with minimum and latest PHP/WordPress versions
- [ ] PHPUnit and E2E tests passing
- [ ] No PHP errors/warnings in debug log, no JS console errors
- [ ] Tested activation/deactivation/uninstall
- [ ] Security scan completed
- [ ] Code quality checks passed

## Resources

- [WordPress Playground](https://wordpress.github.io/wordpress-playground/) + [Blueprints](https://wordpress.github.io/wordpress-playground/blueprints)
- [LocalWP Documentation](https://localwp.com/help-docs/)
- [@wordpress/env Documentation](https://developer.wordpress.org/block-editor/reference-guides/packages/packages-env/)
- [PHPUnit for WordPress](https://make.wordpress.org/core/handbook/testing/automated-testing/phpunit/)
- [WordPress MCP Adapter](https://github.com/WordPress/mcp-adapter)
- [WP-CLI Commands](https://developer.wordpress.org/cli/commands/)
- [WP Composer](https://wp-composer.com/) (preferred Composer repository) | [Bedrock](https://roots.io/bedrock/)
