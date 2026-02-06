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
```text

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

## Overview

This subagent handles WordPress development and debugging tasks:

- Theme and plugin development
- Code debugging and error diagnosis
- Testing environments (Playground, LocalWP, wp-env)
- WordPress MCP Adapter integration
- WP-CLI development commands

## Dependency Verification

### Required Dependencies

Before starting WordPress development, verify these are installed:

```bash
# PHP 7.4+ (8.2 recommended)
php -v

# Composer (package manager)
composer -V

# WP-CLI
wp --version

# Node.js 18+ (for Playground, wp-env, HTTP transport)
node -v
```text

### Installation (macOS)

```bash
# PHP
brew install php@8.2

# Composer
brew install composer

# WP-CLI
brew install wp-cli

# Node.js
brew install node
```text

## WordPress MCP Adapter

The official WordPress MCP Adapter enables AI interaction with WordPress sites.

### Repository Location

```bash
# Clone location (already cloned)
~/git/wordpress/mcp-adapter

# Update to latest
cd ~/git/wordpress/mcp-adapter && git pull
```text

### STDIO Transport (Local Development)

For local WordPress sites with WP-CLI access:

```bash
# Install on WordPress site
cd /path/to/wordpress
composer require wordpress/mcp-adapter

# Activate plugin
wp plugin activate mcp-adapter

# Start MCP server
wp mcp-adapter serve --server=mcp-adapter-default-server --user=admin
```text

### HTTP Transport (Remote Sites)

For remote WordPress sites without SSH:

```bash
# Requires Node.js
npx @automattic/mcp-wordpress-remote

# Environment variables needed
export WP_API_URL="https://your-site.com/wp-json/mcp/mcp-adapter-default-server"
export WP_API_USERNAME="your-username"
export WP_API_PASSWORD="your-application-password"
```text

### Application Passwords

For HTTP transport, create an Application Password:

1. WordPress Admin → Users → Your Profile
2. Scroll to "Application Passwords"
3. Enter name: `mcp-adapter-dev`
4. Click "Add New Application Password"
5. Store securely:

   ```bash
   setup-local-api-keys.sh set wp-app-password-sitename "xxxx xxxx xxxx xxxx"
   ```

## Testing Environments

### WordPress Playground (Quick Testing)

Instant browser-based WordPress for quick tests:

```bash
# Install CLI
npm install -g @wp-playground/cli

# Start with blueprint
npx @wp-playground/cli server --port=8888 --blueprint=blueprint.json
```text

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
```text

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
```text

### LocalWP (Full Development)

Full persistent development environment:

```bash
# Default sites location
~/Local Sites/

# WP-CLI with LocalWP
cd "~/Local Sites/site-name/app/public"
wp plugin list
wp option get siteurl

# LocalWP's WP-CLI path
/Applications/Local.app/Contents/Resources/extraResources/bin/wp-cli.phar
```text

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
```text

### wp-env (Docker/CI)

Docker-based environment for testing:

```bash
# Install
npm install -g @wordpress/env

# Start
wp-env start

# Stop
wp-env stop

# Run WP-CLI
wp-env run cli wp plugin list

# Run tests
wp-env run tests-cli phpunit
```text

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
```text

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
```text

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
```text

### Theme Scaffolding

```bash
# Create block theme
wp scaffold theme theme-name --theme_name="Theme Name" --activate

# Create child theme (for Kadence)
wp scaffold child-theme kadence-child --parent_theme=kadence --activate
```text

### Template Hierarchy

```text
is_front_page()  → front-page.html → home.html → index.html
is_single()      → single-{post-type}-{slug}.html → single-{post-type}.html → single.html → singular.html → index.html
is_page()        → page-{slug}.html → page-{id}.html → page.html → singular.html → index.html
is_archive()     → archive-{post-type}.html → archive.html → index.html
is_category()    → category-{slug}.html → category-{id}.html → category.html → archive.html → index.html
is_search()      → search.html → index.html
is_404()         → 404.html → index.html
```text

## Plugin Development

### Plugin Scaffolding

```bash
# Basic plugin
wp scaffold plugin my-plugin --plugin_name="My Plugin" --activate

# Plugin with CPT
wp scaffold plugin my-plugin --plugin_name="My Plugin" --activate
wp scaffold post-type book --plugin=my-plugin

# Plugin with block
wp scaffold block my-block --plugin=my-plugin
```text

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
```text

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
```text

## Plugin & Theme Analysis Workflow

### Local Development Directory

All plugin and theme development/analysis happens in `~/Git/wordpress/`:

```text
~/Git/wordpress/
├── {plugin-slug}/              # Cloned plugin for analysis/patching
├── {plugin-slug}-addon/        # Custom addon for pro/closed plugins
├── {plugin-slug}-fix/          # Patches that survive updates
├── {theme-slug}/               # Cloned theme
└── {theme-slug}-child/         # Child theme customizations
```text

### Workflow: Analyzing a Plugin/Theme

1. **Clone to local dev folder**:

   ```bash
   # From WordPress plugin directory or GitHub
   cd ~/Git/wordpress
   git clone https://github.com/developer/plugin-slug.git
   
   # Or extract from zip (for pro plugins)
   unzip ~/Downloads/plugin-name.zip -d ~/Git/wordpress/
   mv ~/Git/wordpress/plugin-name ~/Git/wordpress/plugin-slug
   cd ~/Git/wordpress/plugin-slug
   git init
   git add .
   git commit -m "Initial import of plugin-slug v1.0.0"
   ```

2. **Analyze the code**:

   ```bash
   # Use osgrep for semantic search
   osgrep "where does this plugin handle user authentication"
   
   # Or traditional grep
   grep -r "add_action\|add_filter" --include="*.php" .
   ```

3. **Test in LocalWP**:

   ```bash
   # Symlink to LocalWP site
   ln -s ~/Git/wordpress/plugin-slug "~/Local Sites/test-site/app/public/wp-content/plugins/"
   ```

### Workflow: Contributing to Open Source

For open-source plugins/themes where you can submit PRs:

1. **Fork on GitHub** (via web UI)

2. **Clone your fork**:

   ```bash
   cd ~/Git/wordpress
   git clone git@github.com:marcusquinn/plugin-slug.git
   cd plugin-slug
   git remote add upstream https://github.com/original/plugin-slug.git
   ```

3. **Create feature/fix branch**:

   ```bash
   git checkout -b fix/issue-description
   ```

4. **Make changes, test, commit**:

   ```bash
   git add .
   git commit -m "fix: description of the fix"
   git push origin fix/issue-description
   ```

5. **Create PR** on GitHub

### Workflow: Patching Pro/Closed Plugins

For premium plugins or plugins where PRs aren't accepted, create a companion plugin:

1. **Create addon/fix plugin**:

   ```bash
   cd ~/Git/wordpress
   mkdir plugin-slug-fix
   cd plugin-slug-fix
   git init
   ```

2. **Create the fix plugin**:

   ```php
   <?php
   /**
    * Plugin Name: Plugin Slug Fix
    * Description: Patches and fixes for Plugin Slug that survive updates
    * Version: 1.0.0
    * Requires Plugins: plugin-slug
    */
   
   // Ensure original plugin is loaded first
   add_action('plugins_loaded', 'plugin_slug_fix_init', 20);
   
   function plugin_slug_fix_init() {
       // Only run if original plugin is active
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

3. **For filter overrides**:

   ```php
   // Override a filter with higher priority
   add_filter('original_filter', 'my_fixed_filter', 999);
   
   function my_fixed_filter($value) {
       // Your fixed logic
       return $modified_value;
   }
   ```

### Naming Conventions

| Scenario | Folder Name | Example |
|----------|-------------|---------|
| Cloned for analysis | `{slug}` | `readabler` |
| Open source fork | `{slug}` | `flavor` (your fork) |
| Addon for pro plugin | `{slug}-addon` | `kadence-blocks-addon` |
| Fix/patch plugin | `{slug}-fix` | `media-file-renamer-fix` |
| Child theme | `{slug}-child` | `kadence-child` |

### Best Practices for Fix Plugins

1. **Always check if original plugin exists**:

   ```php
   if (!function_exists('original_function')) {
       return;
   }
   ```

2. **Use appropriate hook priority**:
   - Lower number = runs earlier
   - Higher number = runs later (for overrides)
   - Default is 10

3. **Document what you're fixing**:

   ```php
   /**
    * Fix: Original plugin doesn't handle multisite correctly
    * Issue: https://github.com/original/plugin/issues/123
    * Affects: v2.0.0 - v2.3.0
    * Remove when: Fixed in upstream
    */
   ```

4. **Version compatibility checks**:

   ```php
   if (defined('ORIGINAL_PLUGIN_VERSION') && 
       version_compare(ORIGINAL_PLUGIN_VERSION, '2.4.0', '<')) {
       // Apply fix only for versions before 2.4.0
   }
   ```

5. **Keep fixes minimal and targeted**:
   - One fix per function/hook
   - Don't copy entire files
   - Use hooks/filters when possible

### Syncing with LocalWP

```bash
# Create sync script
cat > ~/Git/wordpress/sync-to-local.sh << 'EOF'
#!/bin/bash
PLUGIN_SLUG="$1"
SITE_NAME="${2:-test-site}"

if [ -z "$PLUGIN_SLUG" ]; then
    echo "Usage: sync-to-local.sh plugin-slug [site-name]"
    exit 1
fi

SOURCE="$HOME/Git/wordpress/$PLUGIN_SLUG"
DEST="$HOME/Local Sites/$SITE_NAME/app/public/wp-content/plugins/$PLUGIN_SLUG"

rsync -av --delete \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='vendor' \
    "$SOURCE/" "$DEST/"

echo "Synced $PLUGIN_SLUG to $SITE_NAME"
EOF
chmod +x ~/Git/wordpress/sync-to-local.sh
```text

Usage:

```bash
~/Git/wordpress/sync-to-local.sh readabler-fix my-test-site
```text

## Debugging

### Debug Constants

```php
// wp-config.php
define('WP_DEBUG', true);
define('WP_DEBUG_LOG', true);      // Log to wp-content/debug.log
define('WP_DEBUG_DISPLAY', false); // Don't show on screen
define('SCRIPT_DEBUG', true);      // Use non-minified scripts
define('SAVEQUERIES', true);       // Log database queries
```text

### Debug Log Location

```bash
# View debug log
tail -f ~/Local\ Sites/site-name/app/public/wp-content/debug.log

# wp-env
wp-env run cli tail -f /var/www/html/wp-content/debug.log
```text

### Query Monitor

Essential debugging plugin (included in recommended stack):

```bash
wp plugin install query-monitor --activate
```text

Shows:
- Database queries
- PHP errors and warnings
- HTTP requests
- Hooks and actions
- Template hierarchy
- Memory usage

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
# Theme
wp scaffold theme theme-name

# Child theme
wp scaffold child-theme child-name --parent_theme=parent-name

# Plugin
wp scaffold plugin plugin-name

# Post type
wp scaffold post-type cpt-name --plugin=plugin-name

# Taxonomy
wp scaffold taxonomy tax-name --post_types=cpt-name --plugin=plugin-name

# Block
wp scaffold block block-name --plugin=plugin-name
```text

### Database Commands

```bash
# Export
wp db export backup.sql

# Import
wp db import backup.sql

# Query
wp db query "SELECT * FROM wp_posts LIMIT 5"

# Search/replace
wp search-replace 'old.domain.com' 'new.domain.com' --dry-run
wp search-replace 'old.domain.com' 'new.domain.com'

# Optimize
wp db optimize

# Check tables
wp db check
```text

### Development Commands

```bash
# Shell (interactive PHP)
wp shell

# Eval PHP
wp eval 'echo get_option("siteurl");'

# Generate test data
wp post generate --count=10
wp user generate --count=5

# Cache flush
wp cache flush

# Transient cleanup
wp transient delete --all
```text

## PHPUnit Testing

### Setup

```bash
# With wp-env
wp-env run tests-cli phpunit

# With Composer
composer require --dev phpunit/phpunit
composer require --dev wp-phpunit/wp-phpunit

# Run tests
vendor/bin/phpunit
```text

### Test File Structure

```php
<?php
class Test_My_Plugin extends WP_UnitTestCase {
    
    public function setUp(): void {
        parent::setUp();
        // Setup code
    }
    
    public function tearDown(): void {
        parent::tearDown();
        // Cleanup code
    }
    
    public function test_example() {
        $this->assertTrue(true);
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
```text

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
```text

## E2E Testing

### Playwright

```bash
# Install
npm install -D @playwright/test

# Run
npx playwright test

# Interactive
npx playwright test --ui
```text

### Cypress

```bash
# Install
npm install -D cypress

# Run
npx cypress run

# Interactive
npx cypress open
```text

## Security Scanning

Before committing WordPress code:

```bash
# Scan for secrets
./.agents/scripts/secretlint-helper.sh scan

# Check for hardcoded credentials
grep -r "password\|api_key\|secret" --include="*.php" .
```text

## Related Subagents

| Task | Subagent | Reason |
|------|----------|--------|
| Database inspection | `@localwp` | Read-only SQL access to LocalWP databases |
| Content/maintenance | `@wp-admin` | Admin tasks outside development scope |
| E2E testing | `@browser-automation` | Playwright/Stagehand for UI testing |
| Code quality | `@code-standards` | PHP/JS linting, security scanning |
| Security scanning | `@code-standards` | Snyk, Secretlint for vulnerability detection |
| DNS issues | `@dns-providers` | Cloudflare, Namecheap, Spaceship, 101domains |
| Email testing | `@ses` | Amazon SES configuration |
| SSL/CDN | `@cloudflare` | Cloudflare SSL, caching, security |

## Related Documentation

| Topic | File |
|-------|------|
| Bug fixing workflow | `bug-fixing.md` |
| Code review checklist | `code-review.md` |
| Git branching | `git-workflow.md` |
| Release process | `release-process.md` |
| Error feedback loops | `error-checking-feedback-loops.md` |
| Version management | `version-management.md` |
| Credential setup | `api-key-setup.md` |
| Security policies | `security-requirements.md` |
| Preferred plugins | `wp-preferred.md` |

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
