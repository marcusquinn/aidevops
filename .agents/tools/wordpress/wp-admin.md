---
description: WordPress admin - content management, plugins, maintenance, WP-CLI and MainWP integration
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  webfetch: true
  wordpress-mcp_*: true
  context7_*: true
  task: true
---

# WordPress Admin Subagent

<!-- AI-CONTEXT-START -->
## Quick Reference

- **Sites Config**: `~/.config/aidevops/wordpress-sites.json`
- **Sites Template**: `configs/wordpress-sites.json.txt`
- **MainWP Config**: `configs/mainwp-config.json`
- **Working Dir**: `~/.aidevops/.agent-workspace/work/wordpress/`
- **Preferred Plugins**: See `wp-preferred.md`

**Site Management Options**:

| Method | When to Use |
|--------|-------------|
| wp-helper.sh | Multi-site WP-CLI via wordpress-sites.json |
| WP-CLI (SSH) | Direct access, any site |
| MainWP | Fleet operations, connected sites |
| WordPress MCP | AI-powered admin actions |

**wp-helper.sh Commands**:

```bash
wp-helper.sh --list                          # List all sites
wp-helper.sh production plugin list          # Run on specific site
wp-helper.sh --category client core version  # Run on category
wp-helper.sh --all plugin update --all       # Run on ALL sites
```

**SSH Access by Hosting Type**:

| Hosting | Auth Method | Access Pattern |
|---------|-------------|----------------|
| LocalWP | N/A | `cd ~/Local Sites/site/app/public && wp ...` |
| Hostinger | sshpass | `sshpass -f ~/.ssh/hostinger_password ssh user@host "wp ..."` |
| Closte | sshpass | `sshpass -f ~/.ssh/closte_password ssh user@host "wp ..."` |
| Hetzner | SSH key | `ssh root@server "wp ..."` |
| Cloudron | SSH key | Via Cloudron CLI or SSH |

**Related Subagents**:
- `@mainwp` — Fleet management (sites with MainWP Child)
- `@wp-dev` — Code changes, debugging
- `@hostinger` — Hostinger-hosted site operations
- `@hetzner` — Hetzner server management
- `@dns-providers`, `@cloudflare` — DNS/SSL issues
- `@ses` — Email delivery issues

**Always use Context7** for latest WP-CLI command syntax.
<!-- AI-CONTEXT-END -->

## Site Configuration

```bash
mkdir -p ~/.config/aidevops
cp ~/.aidevops/agents/configs/wordpress-sites.json.txt ~/.config/aidevops/wordpress-sites.json
```

```json
{
  "sites": {
    "local-dev": {
      "name": "Local Development",
      "type": "localwp",
      "path": "~/Local Sites/my-site/app/public",
      "multisite": false,
      "mainwp_connected": false
    },
    "production": {
      "name": "Production Site",
      "type": "hostinger",
      "url": "https://example.com",
      "ssh_host": "ssh.example.com",
      "mainwp_connected": true,
      "mainwp_site_id": 123
    }
  }
}
```

## Content Management

### Posts & Pages

```bash
wp post list --post_type=post --post_status=publish
wp post create --post_type=post --post_title="New Post" --post_status=draft
wp post update 123 --post_title="Updated Title"
wp post delete 123 --force
wp post meta get 123 _thumbnail_id
wp post meta update 123 custom_field "value"
```

### Custom Post Types

```bash
wp post-type list
wp post list --post_type=product --post_status=any
wp post create --post_type=product --post_title="New Product" --post_status=publish
```

### Media

```bash
wp media list
wp media import https://example.com/image.jpg
wp media regenerate --yes
wp post list --post_type=attachment --post_status=inherit --meta_key=_wp_attached_file --format=ids | xargs wp post delete
```

### Taxonomies

```bash
wp term list category
wp term create category "New Category" --description="Description"
wp term list post_tag
wp post term add 123 category "Category Name"
```

### Menus

```bash
wp menu list
wp menu create "Main Menu"
wp menu item add-post main-menu 123
wp menu item add-custom main-menu "Custom Link" https://example.com
wp menu location assign main-menu primary
```

## Plugin Management

```bash
wp plugin list [--status=active]
wp plugin install kadence-blocks --activate
wp plugin install antispam-bee fluent-smtp query-monitor --activate
wp plugin update kadence-blocks
wp plugin update --all [--dry-run]
wp plugin deactivate plugin-name [--all]
wp plugin delete plugin-name
wp plugin search "seo" --fields=name,slug,rating
```

## WordPress Core

```bash
wp core version
wp core check-update
wp core update && wp core update-db
wp option get siteurl
wp option update blogname "My Site"
```

## User Management

```bash
wp user list [--role=administrator]
wp user create john john@example.com --role=editor --user_pass=password
wp user update john --display_name="John Doe"
wp user delete john --reassign=1
wp user reset-password john
wp role list
wp cap add custom_role edit_posts
wp user list-caps john
```

## Backup & Restore

```bash
# Backup
wp db export backup-$(date +%Y%m%d).sql
tar -czf ~/backups/$(date +%Y%m%d)/wp-content.tar.gz wp-content/

# Restore
wp db import backup.sql
wp search-replace 'https://old.com' 'https://new.com' [--dry-run]
wp cache flush && wp rewrite flush
```

## Security

```bash
# Checks
wp core verify-checksums
wp plugin verify-checksums --all
wp user list --role=administrator
find . -type f -perm 777

# Hardening
wp config shuffle-salts
wp config set DISALLOW_FILE_EDIT true --raw
wp config set WP_DEBUG false --raw

# Spam
wp comment delete $(wp comment list --status=spam --format=ids) --force
wp comment list --status=hold
```

## Site Health & Performance

```bash
# Diagnostics
wp site health status
wp cron event list
wp cron event run --due-now
wp transient delete --expired

# Performance
wp db optimize
wp db repair
wp post delete $(wp post list --post_type=revision --format=ids) --force
wp post delete $(wp post list --post_type=post --post_status=auto-draft --format=ids) --force

# Cache
wp cache flush
wp rewrite flush
wp closte devmode enable   # Closte: before changes
wp closte devmode disable  # Closte: after changes
```

## Multisite

```bash
# Sites
wp site list
wp site create --slug=newsite --title="New Site"
wp site activate 2

# Network plugins
wp plugin list --network
wp plugin activate plugin-name --network

# Always use --url for per-site commands
wp post list --url=https://subsite.example.com
wp option get blogname --url=https://subsite.example.com
```

## MainWP Integration

Use `@mainwp` for fleet operations (bulk updates, security scans, centralized backups, monitoring).

```bash
./.agents/scripts/mainwp-helper.sh sites production
./.agents/scripts/mainwp-helper.sh bulk-update-plugins production 123 124 125
./.agents/scripts/mainwp-helper.sh security-scan production 123
```

```bash
# Store MainWP API credentials
setup-local-api-keys.sh set mainwp-consumer-key-production YOUR_KEY
setup-local-api-keys.sh set mainwp-consumer-secret-production YOUR_SECRET
```

## SEO

```bash
wp plugin list | grep -E "seo|rank-math"
wp option get blogname
wp option update blogname "New Site Title"
wp rewrite structure && wp rewrite flush
wp option update rank_math_sitemap_last_modified $(date +%s)
```

## Common Workflows

### Plugin Update Workflow

1. `wp plugin update --all --dry-run` — check what will change
2. `wp db export backup.sql` — backup first
3. `wp plugin update --all`
4. Test site, then `wp cache flush`

### Content Migration

1. `wp export --post_type=post`
2. `wp import export.xml --authors=create`
3. `wp search-replace 'old.com' 'new.com'`
4. `wp media regenerate`

### Site Cloning

1. `wp db export` + `tar -czf site.tar.gz .`
2. Transfer, extract, import database
3. `wp search-replace` + update `wp-config.php`

## Security Checklist

Before bulk operations:
1. **Backup first** — `wp db export`
2. **Staging test** — test on staging before production
3. **Security scan** — run `@mainwp` security scan after changes
4. **Audit log** — document significant changes
