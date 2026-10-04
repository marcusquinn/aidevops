<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WP-CLI Command Reference

Quick-reference for common WP-CLI commands, organized by domain. For site configuration, access patterns, and workflows, see `wp-admin.md`.

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

### Fleet rollout of a self-hosted plugin release

#### Resumable command (operator-controlled)

`wp-fleet-helper.sh` coordinates `plan`, `backup`, `deploy`, `verify` and `report`.
It reads the allowlisted, tenant-aware `wp-helper.sh --export-sites` inventory;
shared server references and SSH aliases retain the existing authentication path.
Inventory, manifests, artifacts, backups and checkpoints are private: never attach
them to public issues. Python 3.6+ and WP-CLI must already exist on selected hosts;
the helper does not install dependencies or contact sites without explicit selection.

```bash
# Replace placeholders; use a private directory outside repository/web roots.
wp-fleet-helper.sh plan --run-dir "<private-run-directory>" \
  --tenant "<tenant>" --sites "<site-id>,<other-site-id>" \
  --scan-parent "<approved-host-parent>" --remote-storage "<private-host-backup-directory>" \
  --slug "<slug>" --repository "<owner/repository>" --tag "<published-tag>" \
  --asset "<published-asset.zip>" --version "X.Y.Z" --sha256 "<trusted-64-character-sha256>"
wp-fleet-helper.sh backup --run-dir "<private-run-directory>"
# Only after reviewing the exact plan, including every logical URL/health state:
wp-fleet-helper.sh deploy --run-dir "<private-run-directory>" \
  --apply --approve "<exact-plan-fingerprint>"
wp-fleet-helper.sh verify --run-dir "<private-run-directory>"
wp-fleet-helper.sh report --run-dir "<private-run-directory>"
```

Planning is read-only on the hosts (WP-CLI bootstrap can still run installed
plugin hooks). It pins a published asset ID, trusted SHA-256, annotated tag commit,
signature verification and successful exact-commit CI. An unverifiable annotated
tag requires an explicit `--trust-decision "<operator-reviewed-rationale>"` recorded
in the fingerprint; unsigned lightweight tags are refused. No release publication,
updater diagnostic, option write or persistent request-limiter bypass is performed.
The expected archive entry point is `<slug>/<slug>.php`; numeric versions only.
Custom plugin locations and symlinked config/plugin trees are refused during
planning rather than risking a different upgrader destination.

Select `--category "<category>"` instead of site IDs, or explicitly opt into bounded
read-only discovery with `--discover-ssh "<SSH-alias>" --scan-parent "<approved-parent>"`
instead of registry selection. Discovery never silently scans an account: depth is
limited to four levels/10,000 directories, symlink directories are not followed,
and canonical roots must remain under the approved parent. Registry aliases are
deduplicated by remote account/host identity plus canonical root; every multisite
URL and its original activation state is captured. All selected installations must
share the approved scan parent; use separate plans otherwise.

By default each URL must return 200 without fatal markers. Use
`--health "<private-expectations.json>"` during planning for explicit per-URL exceptions
(a JSON object mapping exact URLs to HTTP status integers, e.g. a protected staging
URL to 401). Redirect statuses are checked rather than silently following them.
Optional `--audit-argv '["<plugin-command>","audit"]' --audit-read-only` records an
operator-supplied read-only WP-CLI argv and runs it once per logical URL in `verify`.
This attestation is an authority boundary, not a sandbox for untrusted commands;
transport/path/bootstrap override flags and arbitrary shell strings are refused.

Backups contain a WP-CLI DB dump, config and plugin copies, with checksums, private
0700 directories/0600 files, outside the approved scan parent. WP-CLI owns database
authentication and temporary client configuration; control manifests never contain
credential values. Use a known non-web-served host location: the helper cannot
infer every unrelated web server alias. Deployment first checks the entire selected
inventory, every URL, activation/version/bytes and every complete backup. It uses
the normal WordPress upgrader without activation flags, stages one verified ZIP per
host/plan and skips an already-installed release only when **all** files match.

Repeat a phase with `--resume` to revalidate immutable release, scope, backups and
installed bytes; completion flags alone never authorize a reinstall. Checkpoints
are atomic and reports are sanitized counts. Fixed account/canonical-root locks
cover different run IDs and backup directories; they do not prevent native updates
or hosting operations. Lock contention, newer versions, retired roots, changed
inventory, altered bytes or failed health stop the run without shrinking scope.
An interrupted upgrader leaving partial bytes requires operator inspection, not
blind force reinstall. An orphaned published backup/checkpoint or lock also needs
inspection; there is no unsafe stale-lock takeover.

Backups and historical evidence are retained. Failure never automatically restores
plugin files or imports a DB, recreates retired roots, edits content/features or
changes unrelated plugins. Rollback is deliberately not implemented: schema
compatibility and separate authority must be established outside this helper.
Offline stub/filesystem verification is provided by
`bash .agents/scripts/tests/test-wp-fleet-helper.sh`; a real hosting/WordPress
rollout is **not** verified by those tests and requires separately authorized runtime
validation. The release builder remains build/check-only.

#### Explicit updater diagnostic and manual fallback

For a GitHub-updater release, use the GitHub-channel zip built by
[the plugin release workflow](wp-plugin-release.md#release-steps-github-channel).
Before updating the fleet, test one representative site's update check in cron
context (replace the plugin basename with its actual entry file):

```bash
wp eval 'if (!defined("DOING_CRON")) { define("DOING_CRON", true); } $updates = get_site_transient("update_plugins"); if (is_object($updates)) { $updates->last_checked = 0; set_site_transient("update_plugins", $updates); } wp_update_plugins(); $updates = get_site_transient("update_plugins"); $plugin = "<slug>/<slug>.php"; $offer = is_object($updates) ? ($updates->response[$plugin] ?? null) : null; echo $offer ? $offer->new_version . PHP_EOL : "No update offered; inspect updater diagnostics." . PHP_EOL;'
```

HTTP Requests Manager's smart mode can block outbound requests once PHP has run
for 3 seconds or made 3 requests, while exempting cron and `update-core.php`.
A heavy site's WP-CLI bootstrap can exhaust that budget before the updater runs.
Similar request limiters/firewalls may have different exemptions; inspect the
installed version and configuration. The cron constant here affects only this
CLI process, not the site's persistent firewall settings.

"Plugin already updated" is not proof the release is unavailable. Read the error
recorded in the updater's release cache/log before blaming a missing token or
private repository. A recorded `User has blocked requests through HTTP` or
`total_time_limit` error points to request blocking. Inspect only the relevant
error, not a full cache/config dump that might expose credentials. If credentials
need checking, compare SHA-256 fingerprints of the securely stored expected token
and the site's configured constant in a trusted process, reporting only
match/mismatch. Never print either token or put it in CLI arguments or logs.

If the updater remains blocked, use the checksum-verified release zip fallback:

1. Confirm a current backup and the intended version; verify the built release
   asset against its trusted `SHA256SUMS`. Copy it once per host, outside the web
   root, then verify the remote checksum before installing it on any site:

   ```bash
   scp "dist/<slug>-X.Y.Z.zip" "<ssh-host>:<private-release-directory>/"
   ssh "<ssh-host>" 'shasum -a 256 "<private-release-directory>/<slug>-X.Y.Z.zip"'
   ```

2. On the host, run the following for each site from its WordPress root (or use
   `--path`); `--force` replaces the installed plugin files. Preserve the existing
   activation state rather than adding `--activate`:

   ```bash
   wp plugin install "<private-release-directory>/<slug>-X.Y.Z.zip" --force
   wp plugin get "<slug>" --field=version
   curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' "<home-url>"
   ```

3. Require the expected version and front-end status for each site; stop on an
   unexpected result and inspect site logs before continuing. Remove the exact
   copied zip after verification of all sites on that host.

Expected non-200 front ends (admin-only redirects, password-protected staging)
belong in the local site inventory, not shared docs. Compare each response with
that inventory; do not globally treat redirects or authentication errors as
successful health checks.

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

## SEO

```bash
wp plugin list | grep -E "seo|rank-math"
wp option get blogname
wp option update blogname "New Site Title"
wp rewrite structure && wp rewrite flush
wp option update rank_math_sitemap_last_modified $(date +%s)
```
