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

- **Plugin/Theme Dev**: `~/Git/wordpress/{slug}` for analysis, `{slug}-fix` for patches
- **MCP Adapter Repo**: `~/Git/wordpress/mcp-adapter`
- **Local Sites**: `~/Local Sites/`
- **Sites Config**: `~/.config/aidevops/wordpress-sites.json`
- **Working Dir**: `~/.aidevops/.agent-workspace/work/wordpress/`
- **Preferred Plugins**: See `wp-preferred.md` for curated recommendations

**Plugin/Theme Workflow**:
- Clone to `~/Git/wordpress/{slug}/` for analysis
- Fork + PR for open-source contributions
- Create `{slug}-fix/` or `{slug}-addon/` for pro plugin patches (survives updates)

**Dependency Checks** (run first):

```bash
php -v          # >= 7.4
composer -V     # Package manager
wp --version    # WP-CLI
node -v         # >= 18 (for HTTP transport, wp-env, Playground)
```

**WordPress MCP Adapter**:
- STDIO: `wp mcp-adapter serve --server=mcp-adapter-default-server --user=admin`
- HTTP: `npx @automattic/mcp-wordpress-remote`
- Requires: WordPress Abilities API plugin

**Testing Environments**:

| Environment | Best For | Command |
|-------------|----------|---------|
| WordPress Playground | Quick testing | `npx @wp-playground/cli server` |
| LocalWP | Full development | Open Local.app |
| wp-env | CI/CD, PHPUnit | `wp-env start` |

**Related Subagents**:
- `@localwp` - Database inspection during debugging
- `@wp-admin` - Content/maintenance tasks (hand off)
- `@browser-automation` - E2E testing with Playwright
- `@code-standards` - PHP/JS code quality checks

**Related Workflows** (in .agents/workflows/):
- `bug-fixing.md` - Systematic debugging approach
- `code-review.md` - Code review checklist
- `git-workflow.md` - Branching for features/fixes
- `release-process.md` - Plugin/theme releases
- `error-checking-feedback-loops.md` - CI/CD error resolution

**Always use Context7** for latest WordPress/WP-CLI/PHP documentation.

<!-- AI-CONTEXT-END -->

## Installation (macOS)

```bash
brew install php@8.2 composer wp-cli node
```

## Composer-Based WordPress (Bedrock)

For projects that manage WordPress as a Composer project (e.g., [Bedrock](https://roots.io/bedrock/)), use [WP Composer](https://wp-composer.com/) as the Composer repository for plugins and themes. It is the preferred alternative to WPackagist (which was acquired by WP Engine in March 2024).

**Setup:**

```bash
composer config repositories.wp-composer composer https://repo.wp-composer.com
```

**Package naming:** `wp-plugin/{slug}` for plugins, `wp-theme/{slug}` for themes.

**When to use:** Bedrock-style projects where `wp-content` is managed via `composer.json` and the entire site is version-controlled. Not applicable to traditional WordPress installations where plugins are managed via WP-CLI or the admin dashboard (e.g., Closte-hosted sites).

**Migration from WPackagist:** See [migration guide](https://wp-composer.com/wp-composer-vs-wpackagist) or use the [migration script](https://github.com/roots/wp-composer/blob/main/scripts/migrate-from-wpackagist.sh).

## WordPress MCP Adapter

The official WordPress MCP Adapter enables AI interaction with WordPress sites.

```bash
# Clone location (already cloned)
~/git/wordpress/mcp-adapter

# Update to latest
cd ~/git/wordpress/mcp-adapter && git pull
```

### STDIO Transport (Local Development)

```bash
cd /path/to/wordpress
composer require wordpress/mcp-adapter
wp plugin activate mcp-adapter
wp mcp-adapter serve --server=mcp-adapter-default-server --user=admin
```

### HTTP Transport (Remote Sites)

```bash
npx @automattic/mcp-wordpress-remote

export WP_API_URL="https://your-site.com/wp-json/mcp/mcp-adapter-default-server"
export WP_API_USERNAME="your-username"
export WP_API_PASSWORD="your-application-password"
```

### Application Passwords

For HTTP transport, create an Application Password:

1. WordPress Admin → Users → Your Profile
2. Scroll to "Application Passwords"
3. Enter name: `mcp-adapter-dev`
4. Click "Add New Application Password"
5. Store securely: `setup-local-api-keys.sh set wp-app-password-sitename "xxxx xxxx xxxx xxxx"`

## Testing Environments

### WordPress Playground (Quick Testing)

```bash
npm install -g @wp-playground/cli
npx @wp-playground/cli server --port=8888 --blueprint=blueprint.json
```

**Blueprint Example** (`blueprint.json`):

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

### LocalWP (Full Development)

```bash
# Default sites location
~/Local Sites/

# WP-CLI with LocalWP
cd "~/Local Sites/site-name/app/public"
wp plugin list
wp option get siteurl

# LocalWP's WP-CLI path
/Applications/Local.app/Contents/Resources/extraResources/bin/wp-cli.phar
```

**Plugin Sync Script** (`bin/localwp-sync.sh`):

```bash
#!/bin/bash
PLUGIN_SLUG="your-plugin-slug"
SITE_NAME="project-name"
PLUGIN_DIR="$HOME/Local Sites/$SITE_NAME/app/public/wp-content/plugins/$PLUGIN_SLUG"

rsync -av --delete \
  --exclude='node_modules' \
  --exclude='vendor' \
  --exclude='tests' \
  --exclude='.git' \
  ./ "$PLUGIN_DIR/"

echo "Plugin synced to LocalWP"
```

### wp-env (Docker/CI)

```bash
npm install -g @wordpress/env
wp-env start
wp-env stop
wp-env run cli wp plugin list
wp-env run tests-cli phpunit
```

**Configuration** (`.wp-env.json`):

```json
{
  "core": "WordPress/WordPress#6.4",
  "phpVersion": "8.1",
  "plugins": [".", "https://downloads.wordpress.org/plugin/query-monitor.latest-stable.zip"],
  "config": {
    "WP_DEBUG": true,
    "WP_DEBUG_LOG": true,
    "SCRIPT_DEBUG": true
  }
}
```

**Multisite** (`.wp-env.json`):

```json
{
  "core": "WordPress/WordPress#6.4",
  "phpVersion": "8.1",
  "plugins": ["."],
  "config": {
    "WP_DEBUG": true,
    "WP_ALLOW_MULTISITE": true,
    "MULTISITE": true,
    "SUBDOMAIN_INSTALL": false,
    "DOMAIN_CURRENT_SITE": "localhost",
    "PATH_CURRENT_SITE": "/",
    "SITE_ID_CURRENT_SITE": 1,
    "BLOG_ID_CURRENT_SITE": 1
  }
}
```

## Theme Development

### Theme Structure (Block Theme)

```text
theme-name/
├── style.css              # Theme metadata
├── theme.json             # Global settings
├── functions.php          # Theme functions
├── templates/             # Block templates
│   ├── index.html
│   ├── single.html
│   ├── page.html
│   └── archive.html
├── parts/                 # Template parts
│   ├── header.html
│   └── footer.html
└── patterns/              # Block patterns
    └── hero.php
```

### Theme Scaffolding

```bash
wp scaffold theme theme-name --theme_name="Theme Name" --activate
wp scaffold child-theme kadence-child --parent_theme=kadence --activate
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

### Plugin Scaffolding

```bash
wp scaffold plugin my-plugin --plugin_name="My Plugin" --activate
wp scaffold post-type book --plugin=my-plugin
wp scaffold block my-block --plugin=my-plugin
```

### Plugin Header

```php
<?php
/**
 * Plugin Name: My Plugin
 * Plugin URI: https://example.com/my-plugin
 * Description: Plugin description
 * Version: 1.0.0
 * Author: Your Name
 * Author URI: https://example.com
 * License: GPL-2.0+
 * License URI: https://www.gnu.org/licenses/gpl-2.0.txt
 * Text Domain: my-plugin
 * Domain Path: /languages
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

### Local Development Directory

```text
~/Git/wordpress/
├── {plugin-slug}/              # Cloned plugin for analysis/patching
├── {plugin-slug}-addon/        # Custom addon for pro/closed plugins
├── {plugin-slug}-fix/          # Patches that survive updates
├── {theme-slug}/               # Cloned theme
└── {theme-slug}-child/         # Child theme customizations
```

### Naming Conventions

| Scenario | Folder Name | Example |
|----------|-------------|---------|
| Cloned for analysis | `{slug}` | `readabler` |
| Open source fork | `{slug}` | `flavor` (your fork) |
| Addon for pro plugin | `{slug}-addon` | `kadence-blocks-addon` |
| Fix/patch plugin | `{slug}-fix` | `media-file-renamer-fix` |
| Child theme | `{slug}-child` | `kadence-child` |

### Workflow: Analyzing a Plugin/Theme

```bash
cd ~/Git/wordpress
git clone https://github.com/developer/plugin-slug.git

# Or extract from zip (for pro plugins)
unzip ~/Downloads/plugin-name.zip -d ~/Git/wordpress/
cd ~/Git/wordpress/plugin-slug
git init && git add . && git commit -m "Initial import of plugin-slug v1.0.0"

# Analyze
rg "add_action|add_filter" --type php .

# Test in LocalWP
ln -s ~/Git/wordpress/plugin-slug "~/Local Sites/test-site/app/public/wp-content/plugins/"
```

### Workflow: Contributing to Open Source

```bash
cd ~/Git/wordpress
git clone git@github.com:marcusquinn/plugin-slug.git
cd plugin-slug
git remote add upstream https://github.com/original/plugin-slug.git
git checkout -b fix/issue-description
# make changes
git add . && git commit -m "fix: description of the fix"
git push origin fix/issue-description
# Create PR on GitHub
```

### Workflow: Patching Pro/Closed Plugins

Create a companion plugin that survives updates:

```php
<?php
/**
 * Plugin Name: Plugin Slug Fix
 * Description: Patches and fixes for Plugin Slug that survive updates
 * Version: 1.0.0
 * Requires Plugins: plugin-slug
 */

add_action('plugins_loaded', 'plugin_slug_fix_init', 20);

function plugin_slug_fix_init() {
    if (!class_exists('Original_Plugin_Class')) {
        return;
    }

    // Remove problematic hook
    remove_action('init', 'original_problematic_function');

    // Add fixed version
    add_action('init', 'fixed_function');
}

function fixed_function() {
    // Your fixed implementation
}
```

For filter overrides:

```php
// Override a filter with higher priority
add_filter('original_filter', 'my_fixed_filter', 999);

function my_fixed_filter($value) {
    // Your fixed logic
    return $modified_value;
}
```

### Best Practices for Fix Plugins

1. **Always check if original plugin exists**: `if (!function_exists('original_function')) { return; }`
2. **Use appropriate hook priority**: Lower = runs earlier, higher = runs later (default 10)
3. **Document what you're fixing** with issue URL and affected versions
4. **Version compatibility checks**: `version_compare(ORIGINAL_PLUGIN_VERSION, '2.4.0', '<')`
5. **Keep fixes minimal**: One fix per function/hook, use hooks/filters when possible

### Syncing with LocalWP

```bash
cat > ~/Git/wordpress/sync-to-local.sh << 'EOF'
#!/bin/bash
PLUGIN_SLUG="$1"
SITE_NAME="${2:-test-site}"

if [ -z "$PLUGIN_SLUG" ]; then
    echo "Usage: sync-to-local.sh plugin-slug [site-name]"
    exit 1
fi

rsync -av --delete \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='vendor' \
    "$HOME/Git/wordpress/$PLUGIN_SLUG/" \
    "$HOME/Local Sites/$SITE_NAME/app/public/wp-content/plugins/$PLUGIN_SLUG/"

echo "Synced $PLUGIN_SLUG to $SITE_NAME"
EOF
chmod +x ~/Git/wordpress/sync-to-local.sh

# Usage:
~/Git/wordpress/sync-to-local.sh readabler-fix my-test-site
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

### Debug Log Location

```bash
tail -f ~/Local\ Sites/site-name/app/public/wp-content/debug.log
wp-env run cli tail -f /var/www/html/wp-content/debug.log
```

### Query Monitor

Essential debugging plugin:

```bash
wp plugin install query-monitor --activate
```

Shows: database queries, PHP errors/warnings, HTTP requests, hooks and actions, template hierarchy, memory usage.

### OpenCode PHP LSP (Intelephense + WordPress)

If WordPress symbols are unresolved in OpenCode (e.g., `add_action`, `WP_Query`, globals):

1. Configure `~/.config/opencode/config.json` with an explicit Intelephense server and WordPress stubs.
2. Ensure the `command` path points to the actual Intelephense binary installed for OpenCode.
3. Restart the OpenCode session/LSP process after saving config changes.
4. If diagnostics persist, clear/rebuild Intelephense cache and reindex the workspace.

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

Notes:
- Use your local Intelephense path; do not assume `/home/USER/...` exists.
- In OpenCode sessions, do not suggest Claude-specific commands such as `/lsp-restart`.

### Error Diagnosis Workflow

1. **Enable debugging**: Set `WP_DEBUG` constants
2. **Check debug.log**: Look for PHP errors/warnings
3. **Use Query Monitor**: Check admin bar for issues
4. **Inspect database**: Use `@localwp` for SQL access
5. **Check hooks**: Use `wp hook list` or Query Monitor
6. **Profile performance**: Use `wp profile` or Code Profiler Pro

## WP-CLI Development Commands

### Scaffold Commands

```bash
wp scaffold theme theme-name
wp scaffold child-theme child-name --parent_theme=parent-name
wp scaffold plugin plugin-name
wp scaffold post-type cpt-name --plugin=plugin-name
wp scaffold taxonomy tax-name --post_types=cpt-name --plugin=plugin-name
wp scaffold block block-name --plugin=plugin-name
```

### Database Commands

```bash
wp db export backup.sql
wp db import backup.sql
wp db query "SELECT * FROM wp_posts LIMIT 5"
wp search-replace 'old.domain.com' 'new.domain.com' --dry-run
wp search-replace 'old.domain.com' 'new.domain.com'
wp db optimize
wp db check
```

### Development Commands

```bash
wp shell                          # Interactive PHP
wp eval 'echo get_option("siteurl");'
wp post generate --count=10
wp user generate --count=5
wp cache flush
wp transient delete --all
```

## PHPUnit Testing

```bash
# With wp-env
wp-env run tests-cli phpunit

# With Composer
composer require --dev phpunit/phpunit wp-phpunit/wp-phpunit
vendor/bin/phpunit
```

### Test File Structure

```php
<?php
class Test_My_Plugin extends WP_UnitTestCase {

    public function setUp(): void {
        parent::setUp();
    }

    public function tearDown(): void {
        parent::tearDown();
    }

    public function test_post_creation() {
        $post_id = $this->factory->post->create([
            'post_title' => 'Test Post',
            'post_status' => 'publish'
        ]);

        $this->assertIsInt($post_id);
        $this->assertEquals('Test Post', get_the_title($post_id));
    }
}
```

### phpunit.xml

```xml
<?xml version="1.0"?>
<phpunit
    bootstrap="tests/bootstrap.php"
    backupGlobals="false"
    colors="true"
    convertErrorsToExceptions="true"
    convertNoticesToExceptions="true"
    convertWarningsToExceptions="true"
>
    <testsuites>
        <testsuite name="My Plugin Test Suite">
            <directory suffix=".php">./tests/</directory>
        </testsuite>
    </testsuites>
</phpunit>
```

## E2E Testing

```bash
# Playwright
npm install -D @playwright/test
npx playwright test
npx playwright test --ui

# Cypress
npm install -D cypress
npx cypress run
npx cypress open
```

## Security Scanning

```bash
./.agents/scripts/secretlint-helper.sh scan
grep -r "password\|api_key\|secret" --include="*.php" .
```

## Environment Comparison

| Feature | Playground | LocalWP | wp-env |
|---------|------------|---------|--------|
| Setup Time | Instant | 5-10 min | 2-5 min |
| Persistence | None | Full | Partial |
| PHP Versions | Limited | Many | Configurable |
| Database | In-memory | MySQL | MySQL |
| WP-CLI | Yes | Yes | Yes |
| Multisite | Yes | Yes | Yes |
| Docker Required | No | No | Yes |
| GitHub Actions | Works* | N/A | Works |
| Best For | Quick testing | Full dev | CI/Testing |

*Playground may be flaky in CI environments

## Testing Checklist

Before releasing a plugin/theme:

- [ ] Tested on single site
- [ ] Tested on multisite
- [ ] Tested with minimum PHP version
- [ ] Tested with minimum WordPress version
- [ ] Tested with latest WordPress version
- [ ] PHPUnit tests passing
- [ ] E2E tests passing
- [ ] No PHP errors/warnings in debug log
- [ ] No JavaScript console errors
- [ ] Tested activation/deactivation
- [ ] Tested uninstall process
- [ ] Security scan completed
- [ ] Code quality checks passed

## Resources

- [WordPress Playground](https://wordpress.github.io/wordpress-playground/)
- [WordPress Playground Blueprints](https://wordpress.github.io/wordpress-playground/blueprints)
- [LocalWP Documentation](https://localwp.com/help-docs/)
- [@wordpress/env Documentation](https://developer.wordpress.org/block-editor/reference-guides/packages/packages-env/)
- [PHPUnit for WordPress](https://make.wordpress.org/core/handbook/testing/automated-testing/phpunit/)
- [WordPress MCP Adapter](https://github.com/WordPress/mcp-adapter)
- [WP-CLI Commands](https://developer.wordpress.org/cli/commands/)
- [WP Composer](https://wp-composer.com/) (preferred Composer repository for WP plugins/themes)
- [Bedrock](https://roots.io/bedrock/) (Composer-based WordPress boilerplate by Roots)
