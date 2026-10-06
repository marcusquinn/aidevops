---
description: Premium WordPress plugin updates - GPLVault diagnosis and refreshing stale premium plugins from sibling sites
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Premium Plugin Updates

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Symptom**: premium plugins stay old while the dashboard shows few or no updates.
- **First check**: compare versions with sibling sites on the same hosting account; a newer copy elsewhere proves the update channel, not the vendor, is stale.
- **GPLVault scope**: it requests updates only for **active** plugins, so inactive premium plugins never receive updates.
- **Fallback**: after a backup, copy newer plugin folders from a sibling site, one plugin at a time, with a health check and automatic revert.
- **Vendor-side faults**: escalate to the vendor with log evidence; do not loop on clear/reactivate.

<!-- AI-CONTEXT-END -->

## GPLVault Updater

Evidence lives in two places; read both before changing settings:

- Option `gplvault_api_last_response`: last request action, HTTP code, error code, and timestamp.
- Directory `wp-content/uploads/gplvault-logs/`: dated `api-manager-*` and `cron-actions-*` logs. Gaps between dated files show cron did not run.

Observed in GPLVault Updater 5.3.x:

- **Active-only payload**: `GPLVault_API_Manager::schema_payload()` sends only active plugins, so `gplvault_available_plugins` covers only those. Inactive plugins (common on MainWP dashboards and plugin "library" sites) go stale indefinitely.
- **Status is key-scoped**: `status()` can return `activated: true` while the site's instance is unknown to the update service. The admin "Activated" badge and "Already Active" message reflect this status call, not a working update channel.
- **The real test**: `gv_api_manager()->set_initials()->client_schema()` (and `schema()`) inside `wp eval`. Success means updates can flow.
- **`401 gv_api_not_activated` (error 7105)** on client-schema while status says activated: the update service does not recognise this instance. Clear Local Settings followed by Activate takes the "Already Active" shortcut and never registers a new instance, so it cannot fix this. If the same key works for other domains from the same server, collect the evidence and contact GPLVault support.
- **Product ID** is the subscription ID shown in `gplvault_license_status` (`api_key_expirations` → `product_id`). The `id` in `gplvault_client_schema` is the updater plugin's catalogue entry; using it returns "No licensing resources exist".
- Compare credentials across sites by hash (for example `substr(md5($key), 0, 8)`), never by printing the key.

## Refreshing Stale Plugins From Sibling Sites

Use this when the vendor channel is broken or never covers the plugin (for example, inactive plugins under GPLVault). It assumes licensed copies on sites you control.

1. **Inventory**: list `name,version,status` for every WordPress install on the account (`wp --path=<docroot> plugin list --skip-plugins --skip-themes`) and pick the newest copy of each slug the target has.
2. **Compatibility**: for Pro add-ons, confirm the target's base plugin matches the source site's base plugin version (for example, `fluentformpro` with `fluentform`, `seo-by-rank-math-pro` with `seo-by-rank-math`). Skip must-use loader files; their parent plugin regenerates them.
3. **Backup**: dump the database and archive `wp-content/plugins` first. On hosts without `proc_open`, see `services/hosting/hostinger.md` "Database backups without WP-CLI".
4. **Swap**: copy the source folder to `<slug>.new`, move the old folder to a stash directory, then rename `<slug>.new` into place. Keep each swap atomic and per plugin.
5. **Health check**: after each active-plugin swap, request a URL that returns 200 on that site (use `/wp-login.php` when the homepage redirects) and fail on fatal-error text. Restore the stashed folder automatically on failure.
6. **Verify**: active-plugin set unchanged, no new PHP `error_log` entries, admin and REST endpoints respond, rerun the inventory to confirm no gaps, then flush caches.

Steps 1, 2, 4 and 5 are automated by `scripts/wp-plugin-parity-helper.sh`, which runs on the hosting account (`scp` it, or stream it with `ssh <alias> bash -s -- ...`). Run the step 3 backup first; the helper takes none.

```bash
ssh <alias> bash -s -- inventory --target <target-domain> < wp-plugin-parity-helper.sh
ssh <alias> bash -s -- sync --target <target-domain> --stash <stash-dir> \
  --check-path /wp-login.php --dry-run <slug>:<source-domain> < wp-plugin-parity-helper.sh
```

Drop `--dry-run` to apply. Each pair prints `OK|SKIP|FAIL|REVERTED slug old -> new (status)`; the stash is never deleted.

Inactive plugins carry no runtime risk, but still back them up; activation later runs their upgrade routines.

## Related

- `wp-admin.md` - plugin update workflow
- `mainwp.md` - fleet updates and child-site removal
- `services/hosting/hostinger.md` - shared-hosting WP-CLI limits
