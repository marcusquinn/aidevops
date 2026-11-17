<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
---
description: Move a WordPress multisite network from preview/temporary hostnames to its own domain (Hostinger shared hosting), with the folder-path and COOKIE_DOMAIN gotchas
mode: subagent
tools:
  read: true
  bash: true
---

# WordPress Multisite Domain Move

Procedure for moving a subdomain multisite from preview hostnames to its final domain on Hostinger shared hosting. Observed on a 3-site network (752 tables, ~520 MB); all steps ran over SSH with WP-CLI. Placeholders: `<old-host>`, `<new-host>`, `$WP` (the docroot).

Generic single-site equivalents: `wp-admin.md` "Site Cloning", `wp-cli-reference.md` (search-replace). Hostinger paths and limits: `../../services/hosting/hostinger.md`.

## Rules

- Everything before step 4 is read-only or reversible. Run it first and review the output.
- Map every host explicitly (`old=new`), including mapped/template hosts and `www.`. Apply mapped/template hosts first, the network host last.
- Never run `litespeed-purge all` on multisite; purge per blog.
- Do not set `COOKIE_DOMAIN` (see Gotchas).

## Steps

1. **Quiesce writers.** Put the site in maintenance mode or block public/admin traffic (for example a temporary `.htaccess` allow-list for your IP, or the host's maintenance toggle), so no orders, comments or edits land after the backup. Pause any per-network cron runner (for example rename its `enabled` file so it prints "paused"), then wait for in-flight runs: `flock -w 300 <runner.lock> true`. Confirm quiescence: `curl -sI` the front end shows the maintenance/blocked response, and `wp db query "SHOW PROCESSLIST"` shows no application writes. Keep writers stopped through verification or rollback; lift only at step 10.
2. **Back up.**
   - Build a temporary 0600 MySQL option file from `wp config get DB_HOST/DB_NAME/DB_USER/DB_PASSWORD`. This works even when WordPress cannot boot mid-change. Delete it afterwards.
   - Store the dump and tar in a private directory outside every web root (`umask 077`, directory 0700, files 0600).
   - `nice mysqldump --defaults-extra-file=<file> --single-transaction --quick --no-tablespaces <db>` to a raw `.sql`, then `gzip -1`. Verify the `-- Dump completed` trailer and the table count against `wp db tables --all-tables | wc -l`.
   - `tar` every file the move will change (`wp-config.php`, `.htaccess`, `wp-content/fonts`, per-site analytics configs).
3. **Read-only pre-checks.**
   - Per old host: `wp search-replace <old-host> <new-host> --all-tables --dry-run --report-changed-only --skip-columns=guid --skip-plugins` (about 10-16 s each).
   - Unique-key clash check: rows whose key contains the old host where the rewritten key already exists (for example `wp_blogs`, `wp_wu_domain_mappings`, option names, transient keys).
   - `grep -rl <old-host> public_html` excluding `wp-content/uploads` and caches, for each old host. Note local-font CSS (`wp-content/fonts/*.css`) and analytics configs.
   - **3a. Prerequisites for the new hosts** (this procedure provisions nothing): DNS points at the hosting account, each new host is added/routed to this installation in the hosting panel, and an HTTPS certificate is issued and valid. Check with `curl -sI https://<new-host>/`. Do not start step 4 until all three hold.
   - **3b. On-disk edits.** After the database apply, edit only the reviewed grep matches (local-font CSS, analytics configs) to the new host, using the files already tarred in step 2, then re-run the grep.
4. **Apply.** First confirm the prerequisites from step 3a. Per host, mapped/template hosts first, network host last (about 25 s each): `wp search-replace <old-host> <new-host> <network-tables> --skip-columns=guid --skip-plugins`, where `<network-tables>` is the reviewed inventory from `wp db tables --all-tables-with-prefix` (including plugin tables of this network). Use `--all-tables` only if the database is dedicated to this network; otherwise it rewrites other applications' data. Then `wp config set DOMAIN_CURRENT_SITE <new-host>` and read back `wp site list --fields=blog_id,url`. `wp_blogs` and Ultimate Multisite `wp_wu_domain_mappings` hold the same host; the all-tables replace changes both together.
5. **Repair folder paths** (gotcha 1): reverse-replace `/domains/<new-host>/` back to `/domains/<old-host>/` on `wp_options` / `wp_sitemeta` (and per-blog `*_options`), then dry run for `domains/<new-host>`, including JSON-escaped (`domains\/<new-host>`) and URL-encoded (`domains%2F<new-host>`) forms. Expect 0.
6. **Second pass with plugins loaded** (gotcha 3): repeat the dry run without `--skip-plugins` at the new `--url=<new-host>`. Review the report first: exclude filesystem paths (`/domains/<old-host>/...`, including escaped forms) from the apply, for example by limiting `--regex` to URL forms (`https?://<old-host>`) or restricting tables/columns. Apply the remainder, then repeat the step 5 path dry run on affected tables and repair any `domains/<new-host>` matches. A remaining old-host match may be a legitimate folder path (some plugins self-heal stored paths on load).
7. **Outbound/isolation allow-list.** If the site defines an outbound-request allow-list constant, add the new hosts so loopbacks still work.
8. **Purge per blog**: for each changed blog ID, `wp litespeed-purge blog <id>` (never `all`, which empties the whole cache on multisite; see `../../services/hosting/hostinger.md` purge scope table).
9. **Redirects.** In `.htaccess`, place these rules **before** the standard WordPress multisite rewrite block (its earlier `[L]` rules would otherwise handle permalinks and files first). 301 each old host and its `www.` to the new host preserving path and query, excluding `/.well-known/` so the old hosts' certificates can still renew. Test one permalink and one static file on an old host:

   ```apache
   RewriteEngine On
   RewriteCond %{HTTP_HOST} ^(www\.)?<old-host-escaped>$ [NC]
   RewriteCond %{REQUEST_URI} !^/\.well-known/
   RewriteRule ^(.*)$ https://<new-host>/$1 [R=301,L]
   ```

10. **Resume** the cron runner. It enumerates sites from the DB, so new domains need no hPanel change. Confirm the first cycle succeeds.

Rollback: restore the gzip dump with `wp db import` (or `mysql`) and the tarred files; pause the runner first.

## Gotchas

1. **Folder paths contain the old host.** Hostinger's folder is `~/domains/<preview-host>/public_html` and does not move with the domain. A host search-replace also rewrites absolute paths stored in the DB (observed: font-download records, SEO plugin hardening records, an AI plugin settings backup) to a non-existent `~/domains/<new-host>/...`. Fix with step 5.
2. **`COOKIE_DOMAIN` is computed by core** for subdomain installs (`ms_cookie_constants()` sets `'.' . network domain`). `wp eval 'echo COOKIE_DOMAIN;'` prints a value even when `wp-config.php` does not define it. `wp config set COOKIE_DOMAIN` would add a hard-coded constant that blocks per-domain cookies on mapped custom domains. Check `wp config get COOKIE_DOMAIN` first; if it is not defined, leave it.
3. **`--skip-plugins` leaves rows holding plugin classes** (message "Skipping an uninitialized class ..."). Repeat with plugins loaded (step 6).
4. **Domain mappings and `wp_blogs`** carry the same host; both must change together.
5. **On-disk host strings**: local-font CSS and per-site analytics configs embed the host. Grep before and after.
6. **Loopback blocking**: an outbound allow-list may need the new hosts (step 7).

## Verification

- Each new host returns 200 over https; each old host (and `www.`) returns 301 with path and query preserved; `/.well-known/` is not redirected.
- 0 old-host matches outside GUIDs (dry run, plugins loaded, and file grep); 0 `domains/<new-host>` matches in plain, JSON-escaped and URL-encoded forms.
- Login cookie domain is correct on the network host and on a mapped domain (`curl -sI` the login page and read `Set-Cookie`).
- Cron runner cycle succeeds; `error_log` shows no new PHP errors.
