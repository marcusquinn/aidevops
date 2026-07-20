<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WordPress Production Clone to LocalWP

Use this workflow to create a disposable LocalWP clone from an authorized production site. Production is read-only except for explicitly approved temporary export creation and cleanup. Never run import, search-replace, sanitization, plugin changes, or configuration changes against production.

## 1. Inventory and Authorization

1. Read `.aidevops/deployments.yaml` and `.aidevops/wordpress.yaml`; stop if the target deployment, site URL, paths, or multisite state are ambiguous.
2. Confirm authorization, maintenance constraints, source backup coverage, expected database and uploads sizes, free space, and the LocalWP destination.
3. Inventory core/PHP/database versions, active theme and plugins, table prefix, multisite sites and mapped domains, cron, object/page cache, must-use plugins, and external integrations.
4. Record a source rollback reference and checksums. Cloning should not require a production rollback, but export creation can consume storage or expose data.

Read-only inventory examples:

```bash
wp core version --path="<PRODUCTION_WORDPRESS_PATH>"
wp plugin list --status=active --format=json --path="<PRODUCTION_WORDPRESS_PATH>"
wp theme list --status=active --format=json --path="<PRODUCTION_WORDPRESS_PATH>"
wp core is-installed --network --path="<PRODUCTION_WORDPRESS_PATH>"
wp site list --fields=blog_id,url --path="<PRODUCTION_WORDPRESS_PATH>"
```

For a multisite, add the verified `--url="<SOURCE_SITE_URL>"` to every site-scoped command.

## 2. Private Artifact Envelope

Create a private working directory outside the repository, preferably under `${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}` with mode `700`. Database dumps, archives, media, logs containing paths, and sanitization reports are private artifacts. Never put them in Git, issue/PR text, chat, shared cloud folders, or repository fixtures.

Use timestamped names without client, domain, or repository identifiers. Restrict files to mode `600`, record SHA-256 checksums, and keep a deletion list before transfer starts.

## 3. Export and Transfer

1. Prefer the hosting provider backup/export mechanism when it produces a consistent snapshot.
2. Otherwise create a database export with an approved read-consistent method. Check free space first and avoid broad filesystem archives when only `wp-content` is needed.
3. Transfer over a verified SSH host key or an approved encrypted provider channel. Do not disable host-key checking.
4. Verify checksums before import. Do not unpack untrusted archives over an existing LocalWP site.
5. Treat deletion of production-side temporary exports as a separate destructive action requiring exact-path review and confirmation.

Placeholder export example:

```bash
wp db export "<REMOTE_PRIVATE_EXPORT_PATH>" --path="<PRODUCTION_WORDPRESS_PATH>"
sha256sum "<REMOTE_PRIVATE_EXPORT_PATH>"
```

## 4. Prepare LocalWP and Block Side Effects

Create or select a disposable LocalWP site with compatible PHP and database versions. Take a local pre-import database snapshot. Before browsing, cron, queues, or application code can run, block outbound effects at more than one layer:

- Route email to a local capture sink or disable transport.
- Disable WP-Cron and pause queue workers until sanitization is complete.
- Block outbound HTTP by default; allow only explicitly required local endpoints.
- Disable webhook, CRM, analytics, search-index, fulfillment, and notification dispatch.
- Put payment gateways in sandbox/test mode and remove live signing secrets.
- Replace production API credentials with absent or local-only secret references.

Do not rely on a single plugin for containment. Use LocalWP/network controls plus WordPress configuration, and verify blocked test attempts cannot reach external systems.

## 5. Import and Serialization-Safe URL Replacement

Import only into the verified local database. Confirm the destination path and database identity immediately before the command.

```bash
wp db import "<PRIVATE_LOCAL_EXPORT_PATH>" --path="<LOCAL_WORDPRESS_PATH>"
wp search-replace "<SOURCE_URL>" "<LOCAL_URL>" --all-tables-with-prefix --precise --skip-columns=guid --dry-run --path="<LOCAL_WORDPRESS_PATH>"
```

Review the dry-run count and sampled tables. Use `wp search-replace`, not raw SQL, so serialized values remain valid. Check mapped domains and scheme variants separately. Only then run the same command without `--dry-run` against local. Preserve GUIDs unless the project has a documented exception.

For multisite, enumerate every site and perform dry-run then apply per verified source/target URL mapping. Never substitute one broad domain fragment across unrelated mapped sites.

## 6. Sanitize PII and Secrets

Sanitize locally before giving developers, automation, or AI tools access:

- Replace user email, names, addresses, phone numbers, IP addresses, session tokens, password-reset keys, and authentication cookies.
- Remove or synthesize order, subscription, support, form, analytics, and marketing records unless the approved test scope requires them.
- Remove API keys, OAuth tokens, webhook secrets, SMTP credentials, payment metadata, and private file links from options, metadata, custom tables, and configuration.
- Preserve relational shape and representative edge cases with deterministic synthetic values.
- Store only aggregate sanitization counts in the audit record; never log original values.

Run project-specific sanitization first in report/dry-run mode. Review table scope before applying it. Take a second local snapshot before destructive sanitization so the import can be retried without touching production.

## 7. Uploads Strategy

Choose and record one strategy:

- **Full copy** for visual or media regression work when authorization, disk, and privacy permit.
- **Bounded subset** for recent or specifically referenced media.
- **Placeholders** for most development, replacing private files with synthetic assets.
- **Read-through proxy** only when explicitly approved; it leaks local browsing behavior to production and can expose private media.

Scan copied uploads for sensitive documents and executable files. Do not copy caches, backups, logs, or generated derivatives unless required. Preserve relative paths when application behavior depends on them.

## 8. LocalWP Validation

Validate before declaring the clone usable:

1. `home` and `siteurl` resolve to the LocalWP URL for each site.
2. Admin and representative front-end pages load without production redirects or mixed-content requests.
3. Permalinks, media, active theme/plugins, custom tables, and scheduled events are present.
4. Serialization checks and targeted application workflows pass.
5. Email, webhook, payment, cron, queue, analytics, and external API test attempts remain blocked or sandboxed.
6. No production hostname, credential, or unsanitized PII remains in configuration or sampled content.
7. LocalWP database inspection is read-only through `tools/wordpress/localwp.md` where practical.

## 9. Cleanup, Audit, and Rollback

After validation, remove transfer archives, dumps, extracted staging directories, temporary production exports, and command-history exposure. Verify deletion against the prepared list and retain only approved checksums and aggregate evidence.

Record source snapshot/reference, export time, checksums, transfer method, LocalWP site identity, source-to-local URL map, sanitization policy and counts, uploads strategy, side-effect controls, validation results, cleanup completion, operator, and date.

Rollback is local-first: stop the LocalWP site, restore the local pre-import or pre-sanitization snapshot, or delete and recreate the disposable site. Production rollback is only for an independently verified production-side impact and must follow the provider runbook with explicit authorization.
