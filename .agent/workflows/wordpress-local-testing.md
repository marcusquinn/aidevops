# WordPress Local Testing Guide

This guide provides instructions for setting up and running local WordPress testing environments for plugin and theme development.

## Overview

Three primary testing approaches are available:

| Approach | Best For | Setup Time | Persistence |
|----------|----------|------------|-------------|
| **WordPress Playground** | Quick testing, demos | Instant | None |
| **LocalWP** | Full development | 5-10 min | Full |
| **wp-env** | CI/CD, testing | 2-5 min | Partial |

## WordPress Playground CLI

Uses `@wp-playground/cli` for instant browser-based WordPress testing.

### When to Use

- Quick plugin functionality testing
- Verifying admin UI changes
- Testing single site vs multisite behavior
- Demos and screenshots
- CI/CD pipeline testing

### Installation

```bash
npm install -g @wp-playground/cli

# Or as project dependency
npm install --save-dev @wp-playground/cli
```

### Quick Start

```bash
# Start single site on port 8888
npx @wp-playground/cli server --port=8888

# Start with blueprint
npx @wp-playground/cli server --blueprint=blueprint.json
```

### Blueprint Configuration

Create `blueprint.json` for reproducible setups:

```json
{
  "$schema": "https://playground.wordpress.net/blueprint-schema.json",
  "landingPage": "/wp-admin/",
  "login": true,
  "features": {
    "networking": true
  },
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
    },
    {
      "step": "installPlugin",
      "pluginZipFile": {
        "resource": "directory",
        "path": "."
      },
      "options": {
        "activate": true
      }
    }
  ]
}
```

### Multisite Blueprint

```json
{
  "$schema": "https://playground.wordpress.net/blueprint-schema.json",
  "landingPage": "/wp-admin/network/",
  "login": true,
  "steps": [
    {
      "step": "enableMultisite"
    },
    {
      "step": "installPlugin",
      "pluginZipFile": {
        "resource": "directory",
        "path": "."
      },
      "options": {
        "activate": true,
        "networkActivate": true
      }
    }
  ]
}
```

### NPM Scripts

Add to `package.json`:

```json
{
  "scripts": {
    "playground:start": "wp-playground server --port=8888 --blueprint=blueprint.json",
    "playground:start:multisite": "wp-playground server --port=8889 --blueprint=multisite-blueprint.json",
    "playground:stop": "pkill -f 'wp-playground' || true"
  }
}
```

## LocalWP Integration

LocalWP provides a full WordPress environment with database persistence.

### Prerequisites

- LocalWP installed ([localwp.com](https://localwp.com))
- Default sites directory: `~/Local Sites/`

### When to Use

- Testing database migrations
- Long-term development environment
- Testing with specific PHP/MySQL versions
- Network/multisite configuration
- WP-CLI command testing

### Site Setup

1. Open LocalWP
2. Click "+" to create new site
3. Configure:
   - **Name**: `project-name-single` or `project-name-multisite`
   - **PHP Version**: Match production requirements
   - **Web Server**: nginx or Apache
   - **Database**: MySQL 8.0+

### Plugin Sync Script

Create `bin/localwp-sync.sh`:

```bash
#!/bin/bash
set -e

PLUGIN_SLUG="your-plugin-slug"
LOCALWP_SITES="$HOME/Local Sites"
SITE_NAME="project-name-single"
PLUGIN_DIR="$LOCALWP_SITES/$SITE_NAME/app/public/wp-content/plugins/$PLUGIN_SLUG"

# Sync plugin files
rsync -av --delete \
  --exclude='node_modules' \
  --exclude='vendor' \
  --exclude='tests' \
  --exclude='.git' \
  --exclude='dist' \
  --exclude='.env' \
  ./ "$PLUGIN_DIR/"

echo "Plugin synced to LocalWP"
```

### WP-CLI with LocalWP

```bash
# Find WP-CLI path
/Applications/Local.app/Contents/Resources/extraResources/bin/wp-cli.phar

# Create alias
alias lwp='/Applications/Local.app/Contents/Resources/extraResources/bin/wp-cli.phar'

# Use with site
cd "~/Local Sites/project-name/app/public"
lwp plugin list
lwp option get siteurl
```

## wp-env (Docker)

Docker-based environment using `@wordpress/env`.

### Prerequisites

- Docker Desktop installed and running
- Node.js 18+

### Installation

```bash
npm install -g @wordpress/env

# Or as project dependency
npm install --save-dev @wordpress/env
```

### Configuration

Create `.wp-env.json`:

```json
{
  "core": "WordPress/WordPress#6.4",
  "phpVersion": "8.1",
  "plugins": [".", "https://downloads.wordpress.org/plugin/query-monitor.latest-stable.zip"],
  "themes": [],
  "config": {
    "WP_DEBUG": true,
    "WP_DEBUG_LOG": true,
    "SCRIPT_DEBUG": true
  },
  "mappings": {
    "wp-content/uploads": "./uploads"
  }
}
```

### Multisite Configuration

Create `.wp-env.json` for multisite:

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

### Commands

```bash
# Start environment
wp-env start

# Stop environment
wp-env stop

# Destroy and rebuild
wp-env destroy
wp-env start

# Run WP-CLI commands
wp-env run cli wp plugin list
wp-env run cli wp option get siteurl
wp-env run cli wp user list

# Run tests
wp-env run tests-cli phpunit

# Access shell
wp-env run cli bash
```

### NPM Scripts

```json
{
  "scripts": {
    "start": "wp-env start",
    "stop": "wp-env stop",
    "destroy": "wp-env destroy",
    "cli": "wp-env run cli",
    "test:phpunit": "wp-env run tests-cli phpunit",
    "test:phpunit:multisite": "wp-env run tests-cli phpunit --configuration phpunit-multisite.xml"
  }
}
```

## Testing Workflows

### Quick Feature Verification

```bash
# Start Playground
npm run playground:start

# Make code changes
# Refresh browser to see changes

# Stop when done
npm run playground:stop
```

### PHPUnit Testing

```bash
# With wp-env
wp-env run tests-cli phpunit

# With Composer
composer test

# Specific test file
vendor/bin/phpunit tests/test-feature.php

# With coverage
vendor/bin/phpunit --coverage-html coverage/
```

### E2E Testing with Cypress

```bash
# Start environment
npm run start

# Run Cypress
npx cypress run

# Interactive mode
npx cypress open
```

### E2E Testing with Playwright

```bash
# Start environment
npm run start

# Run Playwright
npx playwright test

# Interactive mode
npx playwright test --ui
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

## Debugging Tools

### Query Monitor Plugin

Automatically installed in blueprints above. Access via admin bar to view:
- Database queries
- PHP errors
- HTTP requests
- Hooks and actions

### Debug Bar

```bash
wp-env run cli wp plugin install debug-bar --activate
```

### Error Logging

```php
// wp-config.php additions (via blueprint or config)
define('WP_DEBUG', true);
define('WP_DEBUG_LOG', true);
define('WP_DEBUG_DISPLAY', false);
define('SCRIPT_DEBUG', true);
define('SAVEQUERIES', true);
```

View logs:

```bash
# wp-env
wp-env run cli tail -f /var/www/html/wp-content/debug.log

# LocalWP
tail -f "~/Local Sites/site-name/app/public/wp-content/debug.log"
```

## Common Issues and Solutions

### Port Already in Use

```bash
# Check what's using the port
lsof -i :8888

# Kill the process
kill $(lsof -t -i :8888)
```

### Docker Issues (wp-env)

```bash
# Restart Docker
wp-env stop
docker system prune -f
wp-env start

# Check Docker status
docker ps
docker logs $(docker ps -q --filter name=wordpress)
```

### LocalWP Site Not Starting

1. Check LocalWP logs in the app
2. Verify Docker/services are running
3. Try restarting the site
4. Check for port conflicts

### Playground Won't Start

1. Ensure Node.js 18+ is installed
2. Check npm dependencies: `npm install`
3. View logs: `cat .playground.log`
4. Try different port: `--port=9000`

## Testing Checklist

Before releasing:

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

## Resources

- [WordPress Playground](https://wordpress.github.io/wordpress-playground/)
- [WordPress Playground Blueprints](https://wordpress.github.io/wordpress-playground/blueprints)
- [LocalWP Documentation](https://localwp.com/help-docs/)
- [@wordpress/env Documentation](https://developer.wordpress.org/block-editor/reference-guides/packages/packages-env/)
- [PHPUnit for WordPress](https://make.wordpress.org/core/handbook/testing/automated-testing/phpunit/)
