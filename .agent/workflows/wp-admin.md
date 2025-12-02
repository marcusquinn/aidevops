# WordPress Admin Subagent

---

description: "[DEV-2] WordPress admin - content, customization, maintenance. WP-CLI + MainWP for site management"
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
---

<!-- AI-CONTEXT-START -->
## Quick Reference

- **Sites Config**: `~/.config/aidevops/wordpress-sites.json`
- **MainWP Config**: `configs/mainwp-config.json`
- **Working Dir**: `~/.agent/work/wordpress/`
- **Preferred Plugins**: See `wp-preferred.md` for curated recommendations

**Site Management Options**:

| Method | When to Use |
|--------|-------------|
| WP-CLI (SSH) | Direct access, any site |
| MainWP | Fleet operations, connected sites |
| WordPress MCP | AI-powered admin actions |

**Common WP-CLI Commands**:

```bash
wp post list --post_status=draft
wp plugin update --all
wp core update
wp user list --role=administrator
wp option get siteurl
```

**Related Subagents**:
- `@mainwp` - Fleet management (sites with MainWP Child)
- `@wp-dev` - Code changes, debugging (hand off)
- `@hostinger` - Hostinger-hosted site operations
- `@hetzner` - Hetzner server management

**For DNS/SSL Issues**: `@dns-providers`, `@cloudflare`
**For Email Issues**: `@ses` - Amazon SES configuration

**Always use Context7** for latest WP-CLI command syntax.
<!-- AI-CONTEXT-END -->

## Overview

This subagent handles WordPress administration tasks:

- Content creation and management
- Theme customization and settings
- Plugin management and updates
- Backups and security
- Site maintenance
- User management

## Site Configuration

### WordPress Sites Registry

Sites are tracked in `~/.config/aidevops/wordpress-sites.json`:

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

### Access by Hosting Type

| Hosting | Auth Method | Access Pattern |
|---------|-------------|----------------|
| LocalWP | N/A | `cd ~/Local Sites/site/app/public && wp ...` |
| Hostinger | sshpass | `sshpass -f ~/.ssh/hostinger_password ssh user@host "wp ..."` |
| Closte | sshpass | `sshpass -f ~/.ssh/closte_password ssh user@host "wp ..."` |
| Hetzner | SSH key | `ssh root@server "wp ..."` |
| Cloudron | SSH key | Via Cloudron CLI or SSH |

## Content Management

### Posts & Pages

```bash
# List posts
wp post list --post_type=post --post_status=publish

# Create post
wp post create --post_type=post --post_title="New Post" --post_status=draft

# Update post
wp post update 123 --post_title="Updated Title"

# Delete post
wp post delete 123 --force

# Get post meta
wp post meta get 123 _thumbnail_id

# Set post meta
wp post meta update 123 custom_field "value"
```

### Custom Post Types

```bash
# List CPTs
wp post-type list

# List items of CPT
wp post list --post_type=product --post_status=any

# Create CPT item
wp post create --post_type=product --post_title="New Product" --post_status=publish
```

### Media

```bash
# List media
wp media list

# Import media from URL
wp media import https://example.com/image.jpg

# Regenerate thumbnails
wp media regenerate --yes

# Delete unattached media
wp post list --post_type=attachment --post_status=inherit --meta_key=_wp_attached_file --format=ids | xargs wp post delete
```

### Categories & Tags

```bash
# List categories
wp term list category

# Create category
wp term create category "New Category" --description="Description"

# List tags
wp term list post_tag

# Assign category to post
wp post term add 123 category "Category Name"
```

## Theme Customization

### Theme Management

```bash
# List themes
wp theme list

# Activate theme
wp theme activate kadence

# Update theme
wp theme update kadence

# Get theme mods
wp theme mod list

# Set theme mod
wp theme mod set header_logo 123
```

### Widgets

```bash
# List sidebars
wp sidebar list

# List widgets
wp widget list sidebar-1

# Add widget
wp widget add text sidebar-1 --title="My Widget" --text="Content"

# Move widget
wp widget move text-2 --position=1

# Delete widget
wp widget delete text-2
```

### Menus

```bash
# List menus
wp menu list

# Create menu
wp menu create "Main Menu"

# Add page to menu
wp menu item add-post main-menu 123

# Add custom link
wp menu item add-custom main-menu "Custom Link" https://example.com

# Assign menu to location
wp menu location assign main-menu primary
```

## Plugin Management

### Basic Operations

```bash
# List all plugins
wp plugin list

# List active plugins
wp plugin list --status=active

# Install plugin
wp plugin install kadence-blocks --activate

# Update single plugin
wp plugin update kadence-blocks

# Update all plugins
wp plugin update --all

# Deactivate plugin
wp plugin deactivate plugin-name

# Delete plugin
wp plugin delete plugin-name
```

### Bulk Operations

```bash
# Install multiple plugins
wp plugin install antispam-bee fluent-smtp query-monitor --activate

# Update plugins with dry-run
wp plugin update --all --dry-run

# Deactivate all plugins (troubleshooting)
wp plugin deactivate --all
```

### Plugin Search

```bash
# Search WordPress.org
wp plugin search "seo" --fields=name,slug,rating

# Check for updates
wp plugin update --all --dry-run
```

## WordPress Core

### Updates

```bash
# Check version
wp core version

# Check for updates
wp core check-update

# Update core
wp core update

# Update database
wp core update-db
```

### Configuration

```bash
# Get option
wp option get siteurl
wp option get blogname

# Set option
wp option update blogname "My Site"
wp option update admin_email "admin@example.com"

# List all options
wp option list
```

## User Management

### User Operations

```bash
# List users
wp user list

# List admins
wp user list --role=administrator

# Create user
wp user create john john@example.com --role=editor --user_pass=password

# Update user
wp user update john --display_name="John Doe"

# Delete user
wp user delete john --reassign=1

# Reset password
wp user reset-password john
```

### Roles & Capabilities

```bash
# List roles
wp role list

# Create role
wp role create custom_role "Custom Role"

# Add capability to role
wp cap add custom_role edit_posts

# Check user capabilities
wp user list-caps john
```

## Backup Operations

### Database Backup

```bash
# Export database
wp db export backup-$(date +%Y%m%d).sql

# Export specific tables
wp db export --tables=wp_posts,wp_postmeta

# Import database
wp db import backup.sql
```

### Full Site Backup

```bash
# Create backup directory
mkdir -p ~/backups/$(date +%Y%m%d)

# Export database
wp db export ~/backups/$(date +%Y%m%d)/database.sql

# Archive wp-content
tar -czf ~/backups/$(date +%Y%m%d)/wp-content.tar.gz wp-content/

# Archive uploads only
tar -czf ~/backups/$(date +%Y%m%d)/uploads.tar.gz wp-content/uploads/
```

### Restore

```bash
# Restore database
wp db import backup.sql

# Search-replace URLs if needed
wp search-replace 'https://old.com' 'https://new.com' --dry-run
wp search-replace 'https://old.com' 'https://new.com'

# Flush caches
wp cache flush
wp rewrite flush
```

## Security

### Security Checks

```bash
# Check file permissions
find . -type d -perm 777
find . -type f -perm 777

# List admin users
wp user list --role=administrator

# Check for core modifications
wp core verify-checksums

# Check plugin integrity
wp plugin verify-checksums --all
```

### Security Hardening

```bash
# Regenerate salts
wp config shuffle-salts

# Update admin password
wp user update admin --user_pass="new-secure-password"

# Disable file editing
wp config set DISALLOW_FILE_EDIT true --raw

# Disable debug in production
wp config set WP_DEBUG false --raw
```

### Spam Management

```bash
# Delete spam comments
wp comment delete $(wp comment list --status=spam --format=ids) --force

# List pending comments
wp comment list --status=hold

# Approve comment
wp comment approve 123
```

## Site Health

### Diagnostics

```bash
# Check site health
wp site health status

# Check cron
wp cron event list

# Run missed cron
wp cron event run --due-now

# Check transients
wp transient list

# Clean expired transients
wp transient delete --expired
```

### Performance

```bash
# Optimize database
wp db optimize

# Repair database
wp db repair

# Clean revisions
wp post delete $(wp post list --post_type=revision --format=ids) --force

# Clean auto-drafts
wp post delete $(wp post list --post_type=post --post_status=auto-draft --format=ids) --force
```

### Cache Management

```bash
# Flush object cache
wp cache flush

# Flush rewrite rules
wp rewrite flush

# For Closte (LiteSpeed)
wp closte devmode enable  # Before making changes
wp closte devmode disable # After changes
```

## Multisite Operations

### Site Management

```bash
# List sites
wp site list

# Create site
wp site create --slug=newsite --title="New Site"

# Activate site
wp site activate 2

# Delete site
wp site delete 2 --yes
```

### Network Operations

```bash
# List network plugins
wp plugin list --network

# Network activate plugin
wp plugin activate plugin-name --network

# Network deactivate plugin
wp plugin deactivate plugin-name --network
```

### Per-Site Commands

Always use `--url` flag for multisite:

```bash
wp post list --url=https://subsite.example.com
wp plugin list --url=https://subsite.example.com
wp option get blogname --url=https://subsite.example.com
```

## MainWP Integration

For sites with MainWP Child connected, use `@mainwp` subagent for fleet operations:

### When to Use MainWP

- Bulk updates across multiple sites
- Fleet-wide security scans
- Centralized backup management
- Monitoring and reporting
- Site sync operations

### MainWP Commands

```bash
# List all sites
./.agent/scripts/mainwp-helper.sh sites production

# Bulk update plugins
./.agent/scripts/mainwp-helper.sh bulk-update-plugins production 123 124 125

# Security scan
./.agent/scripts/mainwp-helper.sh security-scan production 123
```

## SEO Tasks

### Rank Math / SEO Plugins

```bash
# Check SEO plugin status
wp plugin list | grep -E "seo|rank-math"

# Get site title
wp option get blogname

# Get site description
wp option get blogdescription

# Update title
wp option update blogname "New Site Title"

# Check permalinks
wp rewrite structure
wp rewrite flush
```

### XML Sitemaps

```bash
# Regenerate sitemaps (Rank Math)
wp option update rank_math_sitemap_last_modified $(date +%s)

# Check robots.txt
curl https://example.com/robots.txt
```

## Hosting-Specific Notes

### Hostinger

```bash
# Connect to Hostinger site
sshpass -f ~/.ssh/hostinger_password ssh -p 65002 user@server "cd /domains/example.com/public_html && wp plugin list"

# See hostinger.md for full details
```

### Closte

```bash
# Enable dev mode before changes
wp closte devmode enable

# Make changes...

# Disable dev mode after
wp closte devmode disable

# Flush cache
wp cache flush

# See closte.md for full details
```

### Cloudron

```bash
# Access via Cloudron CLI or SSH
# See cloudron.md for full details
```

### Hetzner

```bash
# SSH key-based access
ssh root@server-ip "cd /var/www/site && wp plugin list"

# See hetzner.md for full details
```

## Related Subagents

| Task | Subagent | Reason |
|------|----------|--------|
| Fleet management | `@mainwp` | Bulk operations on MainWP-connected sites |
| Code changes | `@wp-dev` | Development and debugging tasks |
| Hostinger sites | `@hostinger` | Hostinger-specific SSH, domains, DNS |
| Hetzner servers | `@hetzner` | Server management, firewalls, volumes |
| Cloudron apps | See `cloudron.md` | Cloudron WordPress app management |
| Closte hosting | See `closte.md` | Closte-specific operations (sshpass) |
| DNS management | `@dns-providers` | Cloudflare, Namecheap, Spaceship, 101domains |
| Email delivery | `@ses` | Transactional email, SPF, DKIM |
| SSL/CDN | `@cloudflare` | Cloudflare configuration |
| Browser testing | `@browser-automation` | Visual regression, Stagehand |

## Related Documentation

| Topic | File |
|-------|------|
| MainWP management | `mainwp.md` |
| Hostinger hosting | `hostinger.md` |
| Closte hosting | `closte.md` |
| Cloudron apps | `cloudron.md` |
| Hetzner servers | `hetzner.md` |
| DNS providers | `dns-providers.md` |
| Email (SES) | `ses.md` |
| Credential setup | `api-key-setup.md` |
| Security policies | `security.md` |
| Preferred plugins | `wp-preferred.md` |
| Version tracking | `version-management.md` |

## Security & Credentials

### SSH Access by Hosting Type

| Hosting | Auth Method | Credential Location |
|---------|-------------|---------------------|
| LocalWP | N/A | Auto-detected |
| Hostinger | sshpass | `~/.ssh/hostinger_password` |
| Closte | sshpass | `~/.ssh/closte_password` |
| Hetzner | SSH key | `~/.ssh/id_ed25519` |
| Cloudron | SSH key | `~/.ssh/id_ed25519` |

### MainWP Credentials

```bash
# Store MainWP API credentials
setup-local-api-keys.sh set mainwp-consumer-key-production YOUR_KEY
setup-local-api-keys.sh set mainwp-consumer-secret-production YOUR_SECRET
```

### WordPress Admin Security

When performing admin tasks:

1. **Backups first**: Always backup before bulk updates
2. **Staging test**: Test updates on staging before production
3. **Security scan**: Run `@mainwp` security scan after changes
4. **Audit log**: Document significant changes

## Common Workflows

### Plugin Update Workflow

1. Check for updates: `wp plugin update --all --dry-run`
2. Backup database: `wp db export backup.sql`
3. Enable maintenance mode (if needed)
4. Update plugins: `wp plugin update --all`
5. Test site functionality
6. Clear caches: `wp cache flush`

### Content Migration

1. Export content: `wp export --post_type=post`
2. Transfer file to new site
3. Import: `wp import export.xml --authors=create`
4. Update URLs: `wp search-replace 'old.com' 'new.com'`
5. Regenerate thumbnails: `wp media regenerate`

### Site Cloning

1. Export database: `wp db export`
2. Archive files: `tar -czf site.tar.gz .`
3. Transfer to new server
4. Extract and import database
5. Update URLs: `wp search-replace`
6. Update wp-config.php settings
