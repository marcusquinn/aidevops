---
description: Preferred conventional WordPress hosting and management via REST API and SSH
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hostinger Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Recommendation**: Preferred starting point for conventional WordPress when managed convenience and value lead; verify current plan limits, regions, backups, and support against user priorities
- **Alternatives**: Prefer Hetzner for self-managed control/price-performance; prefer Cloudflare for edge/static/headless workloads or global delivery/security
- **Type**: Shared/VPS/Cloud hosting, budget-friendly
- **API**: REST at `https://developers.hostinger.com`
- **Auth**: Bearer token in `~/.config/aidevops/credentials.sh` as `HOSTINGER_API_TOKEN`
- **SSH**: Port 65002, key auth (recommended) or password auth; framework prefers key when `ssh_identity_file` is configured
- **Credential scope**: Hostinger SSH access is hosting-account scoped, not domain scoped; inventory and group sites before requesting credentials
- **Panel**: Custom hPanel
- **No MCP required** — uses curl for API, ssh for key auth or sshpass for password auth

<!-- AI-CONTEXT-END -->

## Configuration

### Discover account boundaries first

Before asking for SSH credentials, use the Hostinger API token to inventory websites and group them by account `username`. Domains with the same username share one SSH login and must reuse one server/account configuration. Do not request or store duplicate credentials per domain.

Connection metadata (`ssh_host`, `ssh_port`, `ssh_user`, and domain paths) belongs in configuration and is not a password. Store only the shared password or private key securely. For WordPress fleets, prefer `wordpress-sites.json` `servers` plus per-site `server_ref`; `wp-helper.sh` supports an account-level `ssh_password_env` reference.

Name secrets by account alias rather than site, for example `HOSTINGER_SSH_PASSWORD_ACCOUNT_1`. Run commands with the referenced secret injected:

```bash
aidevops secret set HOSTINGER_SSH_PASSWORD_ACCOUNT_1
aidevops secret HOSTINGER_SSH_PASSWORD_ACCOUNT_1 -- \
  wp-helper.sh example-site plugin list
```

Only request another SSH credential when API inventory, the hosting panel, or a failed authenticated probe shows a genuinely different account/server.

### Fleet inventory and drift

`hostinger-helper.sh fleet` is read-only, except `fleet provision --apply`: it never changes hosting, and nothing else changes GitHub, repositories or `repos.json`. It writes private (0600) JSON to `~/.aidevops/.agent-workspace/work/hostinger-fleet/`, and the API token is injected from the secret store automatically.

```bash
hostinger-helper.sh fleet inventory --discover-networks --ssh <account-alias>
hostinger-helper.sh fleet drift --owner <org> --owner-exception <domain>=<personal-login> \
  --site-repo <review-host>=<production-domain>
hostinger-helper.sh fleet plan  --owner <org>   # content-hashed plan for onboarding
hostinger-helper.sh fleet ready [--worker-evidence] [--fail-on-not-ready]
hostinger-helper.sh fleet provision [--site <domain>]   # read-only preview of the saved plan
hostinger-helper.sh fleet provision --apply --plan-sha256 <hash>
hostinger-helper.sh fleet move --site <domain>          # read-only preview of a layout move
hostinger-helper.sh fleet move --site <domain> --apply --confirm <fleet-plan-hash>
hostinger-helper.sh fleet privacy-sync        # offline sync from the saved inventory
```

- **Inventory** fetches every page of `GET /api/hosting/v1/websites` and refuses a partial result. Sites that share an account document root form one codebase: the primary holds the shared code, and the other sites are `network-member` (WordPress) or `alias`.
- **`--discover-networks`** runs a fixed, read-only SSH probe (`wp core is-installed --network`, `wp site list`) on every `domains/*/public_html` root. It adds multisite blogs that have no panel entry. The panel's `website_type` is not reliable: a live multisite network was reported as `other`. Use `--network-map FILE` (blog → primary JSON) when SSH is unavailable.
- **Plan and drift** compare each site, using `<owner>/<domain>` repository names, against `repos.json` and the owner layout in `reference/repo-organization.md`. Results: `ok`, `ok-exception`, `new`, `unregistered-clone`, `missing-clone`, `misplaced`, `owner-mismatch`, `collision`, `ambiguous` and `not-in-hosting`. `drift --fail-on-drift` exits 3 when there is drift.
- **Fleet config** (optional) lives in `~/.config/aidevops/hosting-fleet.json`. It must be a regular 0600 file. It stores `owner`, `owner_exceptions` (`{domain: owner}`), `site_repos` (`{hosted-domain: repo}`) and `ignore` (`[domain]`); command-line flags add to it, and `--owner` overrides it. Use `--site-repo HOST=REPO` when a hosted site is served by a repository with a different name, for example a pre-launch review subdomain whose future production domain names the repository. Several hosts may share one mapped repository, and their clean state is `ok-exception`.
- **Privacy sync** runs automatically after inventory (including offline `--api-response` and custom `--output` inventories). Run `fleet privacy-sync [--inventory FILE] [--config FILE]` to protect an existing inventory without API access. It adds `client:` entries for fleet domains and configured site-repo names, plus `repo:owner/name` entries when the config supplies an owner, to `~/.aidevops/configs/privacy-guard-private-entities.txt` (0600). Configured `ignore` and `owner_exceptions` domains and their mapped repository names are excluded. Missing config still protects inventory domains; it only omits repo slugs. Existing manual entries and comments are preserved, colon/tab entries are deduplicated, concurrent syncs are serialized, and output contains counts only. Sync is additive: exclusions do not remove previously recorded or manual entries. Invalid config or an unsafe destination fails the command rather than silently skipping protection.
- **Readiness** (`fleet ready`, same options as `plan`) checks each plan repository once, even when several hosts share it. Problems block readiness: a non-clean plan state; a remote that is missing, public, archived, under another owner or lacks push permission; a missing remote or local `origin/<default>` ref; a missing clone or wrong `origin`; an invalid project config or a required feature (`planning`, `git_workflow`, `code_quality`) explicitly `false`; and Pulse off or maintenance `false`. Warnings do not block: no admin permission, a stale local default ref, no `origin/HEAD`, registry feature labels that are not effective, and a missing local `.aidevops.json`. Native gates then use defaults, so a missing config is not an opt-out; `aidevops project-config restore <slug>` previews the repair. `all_ready` is true only when every repository is ready and `gh` is authenticated. The result is *configured* readiness, and `--worker-evidence` adds each repository's latest merged `origin:worker` PR as separate evidence. The receipt is written to `readiness.json`. `--fail-on-not-ready` exits 4.
- **Provisioning** (`fleet provision`) reads the saved `plan.json` and acts only on `new` (remote, clone, init, deliver), `unregistered-clone` (init, deliver) and `missing-clone` (clone) repositories. Without `--apply` it is a read-only preview and writes nothing. `--apply` is account mutation and needs operator authority for each run: it requires the exact `--plan-sha256` you reviewed, and it refuses a plan older than 24 hours or one that the current fleet config contradicts (owner, ignore, site repos or owner exceptions changed). Each step re-reads live state, so a repeat run resumes and adopts finished work. **Remote** adopts an existing private repository under the expected owner, refuses a public or foreign one, and otherwise runs `gh repo create <owner>/<repo> --private --add-readme` in the workspace. **Clone** runs `gh repo clone` and refuses a destination with a different `origin`. **Init** runs native `aidevops init planning,git-workflow,code-quality`, which commits in a linked `chore/aidevops-init` worktree and registers the canonical path; init refuses a slug registered elsewhere. **Deliver** pushes that branch and opens an issue and linked PR through `gh-write-helper.sh`, then reports `pending`. It never merges: merge with `full-loop-helper.sh merge`, then re-run to record `complete`. A closed, unmerged init PR is a failure that needs a decision. Steps stop at the first failure or pending PR, the result is per repository (`complete`, `pending`, `planned`, `failed`) and never summarised as success, and `--apply` appends each step to `provision-<plan-hash>.jsonl` (0600). Any failure exits 5. Then run `fleet ready`.
- **Layout moves** (`fleet move`) repair `misplaced` sites. Every site must be named with `--site`, and any site that is not `misplaced` is refused. The preview is read-only and prints each move, the current maintenance/Pulse flags and the fleet plan hash. `--apply --confirm <hash>` needs fresh operator authority each time. It recomputes the plan and refuses a different hash. It then records each repository's flags in an owner-private snapshot (`move-automation-*.json`) and pauses each one with `aidevops repos maintenance off`. Next it writes a scoped native `migrate-layout plan --source ... --include-registered-paths` and refuses it unless its moves match exactly. Planning happens after the pause because the native plan records `repos.json` as a consumer before-state. Native `migrate-layout apply` then streams progress, with no wrapper timeout, and both flags are restored by slug with `maintenance on` and then `aidevops repos pulse on`, since `maintenance on` leaves Pulse off. The flags are read back as proof. A refusal or failure before anything moved restores automation and exits 6. A partial move stays paused: finish it with the printed native resume command, then run `fleet move --restore <snapshot>`, which refuses unless every move or none happened. A new apply is refused while an unfinished snapshot covers the same repositories, so paused flags are never recorded as the originals.
- **Repairs** are separate, explicitly authorised steps.

### PHP runtime

Read-only observations from one managed-hosting account on **2026-10-05**, not universal plan defaults: LiteSpeed Enterprise with persistent `lsphp` workers (some alive for over a day), `LSPHP_ProcessGroup=on`, `LSAPI_CHILDREN=180`, `LSAPI_MAX_IDLE_CHILDREN=90`, `LSAPI_MAX_IDLE=600`, and `LSAPI_MAX_PROCESS_TIME=300`; CloudLinux LVE cgroup membership. Web SAPI and effective account limits still require per-site verification.

The observed OPcache configuration was 1024M memory, 130,987 maximum accelerated files, and 64M interned strings; JIT was off and preload unset. PHP 8.5 **CLI** reported `memory_limit=12288M`: this is not evidence of the web limit or available account RAM. Verify web settings in the application's status page and hPanel → PHP Configuration. Worker counts and OPcache size are host-controlled on managed hosting; do not replace working LSAPI with FPM or attempt pool edits.

Supported per-site overrides can use `.htaccess` `php_value` inside `<IfModule lsapi_module>`; confirm the directive is allowed before proposing a change. Really Simple Security was observed writing `auto_prepend_file` into both that block and `.user.ini`; a migrated site retained a stale `.user.ini` path from its previous account. Inspect only authorized site files and preserve security-plugin ownership when proposing a backed-up repair.

Dated uploads directories returned 403 in this observation. Verify directory-listing protection per site rather than assuming it applies to every account. For the read-only baseline, worker/memory sizing, OPcache assessment, host boundaries, and safe directory-listing remediation, read `tools/runtime/php-server-admin.md`.

### Read-only audit notes

Observed on shared hosting on **2026-10-14**; recheck per account rather than treating these as universal plan defaults.

- **Jailed shell**: No `/dev/fd`; Bash process substitution (`< <(...)`) fails with `/dev/fd/62: No such file or directory`. Use pipes or variables in scripts copied to the host.
- **Missing commands**: `crontab` and `rpm` are unavailable; `convert`, `magick` and `ldd` are not on PATH, and there are no `phpX.Y` commands. Cron jobs live in hPanel. The default `php` is the account's PHP; every available build (5.2–8.5 observed) is at `/opt/alt/phpXX/usr/bin/php`. Answer support's Imagick version check with those paths, for example `/opt/alt/php83/usr/bin/php -r 'echo Imagick::getVersion()["versionString"], PHP_EOL;'`. PHP 5.2 and 5.3 cannot run this one-liner because they lack function array dereferencing.
- **Disabled PHP functions**: Both `shell_exec()` and `proc_open()` are disabled. The latter already prevents `wp db query`; calling either in `wp eval` ends in WordPress's “critical error” message.
- **Shared image library**: Every available PHP build (5.2–8.5) loads the same ImageMagick library (7.1.2-31 observed). Switching PHP does not change it; only Hostinger can update it. Customers can disable `imagick` per website in hPanel's PHP Configuration (**exact control wording unverified**). WordPress then uses GD; the observed GD builds on PHP 8.1+ support WebP and AVIF. Ghostscript is `/usr/bin/gs` (9.27 observed) and used through Imagick for PDF thumbnails; check with `/usr/bin/gs --version`. Without `rpm`, ask the host whether the package carries later security fixes.
- **Site PHP builds**: hPanel's per-website PHP version is not readable from the shell. To see the builds serving sites right now, list the account's processes with `ps -u "$(id -u)" -o pid= -o comm=` and run `readlink /proc/<pid>/exe` for each `lsphp` process, replacing `<pid>` with its PID (for example, the executable may be `/opt/alt/php85/usr/bin/lsphp`). Idle sites may have no worker at that moment.
- **CLI versus web PHP**: WP-CLI uses PHP CLI with `memory_limit=12288M`, no time limit and OPcache off; it cannot report web-request OPcache use. Read stored web-request data from options with `wp eval-file --skip-plugins --skip-themes`, or inspect an admin page.

### WordPress multisite cron and update readiness

During a WordPress multisite migration, setup, or health check, audit cron coverage
and automatic-update readiness before relying on traffic-triggered cron. Shared
plugin files and network-wide updates do not make child-site queues shared; confirm
each active child has scheduler coverage and preserve the existing update policy.
For the audit, safe rollout, verification, and targeted recovery procedure, read
[WordPress multisite cron and automatic-update readiness](hostinger-wordpress-cron.md).

### New WordPress sites: Hostinger default plugins

On creation or first setup through hPanel, the Hostinger API, or an addon website, work over `ssh <alias>`, one site at a time (shared-account connection limits). Inventory installed plugins and all `hostinger*` plugin folders; report other matches without acting on them. Target only `hostinger-ai-assistant` (Hostinger AI) and `hostinger-easy-onboarding` (Hostinger Easy Onboarding); skip absent plugins on every run.

Deactivate the installed targets by default, without prompting; this is reversible and neither is needed to run the site. Leave Hostinger Tools (`hostinger`, maintenance mode/redirects) and the `hostinger-auto-updates.php` must-use plugin untouched.

```bash
# Replace <domain>; pass only installed target slugs.
wp --path="$HOME/domains/<domain>/public_html" plugin deactivate hostinger-ai-assistant hostinger-easy-onboarding
```

On multisite, inspect `is_plugin_active_for_network()` and deactivate network-wide as well as on every affected child site. Re-read `active_plugins` for each site and network activation after deactivation: Freesoul Deactivate Plugins can revert WP-CLI writes. If either target remains active anywhere, stop before deletion and report it.

Ask once: “Delete these unused plugins after backing them up? Recommended: yes, unless you use Hostinger's AI writer or onboarding checklist.” No answer means no deletion; retain them if declined. On explicit yes, verify the account's `~/backups/` directory (create it if absent), then archive only installed target folders:

```bash
# Replace placeholders; omit absent folders and verify the archive before removal.
tar -czf "$HOME/backups/hostinger-plugins-<domain>-before-removal-<date>.tar.gz" -C "<plugins-dir>" hostinger-ai-assistant hostinger-easy-onboarding
```

Hostinger shared hosting can reject `wp plugin uninstall` with “Cannot do 'launch': proc_open() … disabled”. Instead, upload a small temporary PHP file with `scp` and run `wp --path="<docroot>" eval-file "<temporary-php-file>"`. Include `wp-admin/includes/plugin.php` and `wp-admin/includes/file.php`; derive installed plugin file basenames for only the two targets, call `deactivate_plugins($files, true)` (also with the network-wide argument where needed), verify inactivity again, then call `uninstall_plugin($file)` for each `is_uninstallable_plugin($file)`, followed by `delete_plugins($files)`. Check errors, verify removal, and delete the temporary PHP file afterwards; restore folders from the archive if recovery is needed.

Record discovery, deactivation, deletion consent/outcome, and backup location only in private site inventory notes (`~/.config/aidevops/site-inventory.json`), never public content. No site-plugin recommendation is required for this procedure.

### Retiring a website

`DELETE /api/hosting/v1/websites/{domain}` permanently removes a main or addon website with its files, databases and configuration; the plan stays. It rejects parked domains and subdomains, and it runs asynchronously (returns "Request accepted").

1. **Confirm the target**: `GET /api/hosting/v1/websites?domain=<domain>` must return `vhost_type` `main` or `addon`. Check that no other site's `wp-config.php` uses its database.
2. **Back up** files (`tar` of `~/domains/<domain>`) and the database (see "Database backups without WP-CLI"), then verify the archive file count and dump table count.
3. **Detach managers first**: remove the site from MainWP (`tools/wordpress/mainwp.md` "Removing a child site over SSH") while the child plugin can still respond.
4. **Delete**, wait about a minute, then verify: the website list returns no entry, `~/domains/<domain>` is gone, and `GET /api/hosting/v1/accounts/{username}/databases` no longer lists its database.
5. **Clean up leftovers the delete does not touch**: account cron jobs pointing at the old docroot (`GET`/`DELETE /api/hosting/v1/accounts/{username}/cron-jobs[/{uid}]`) and external DNS records (for example Cloudflare).

Take `{username}` from the website list response inside the same command; tool output may redact it, and a copied placeholder silently produces an empty response.

### Legacy Hostinger helper

Copy template and edit with server details:

```bash
cp configs/hostinger-config.json.txt configs/hostinger-config.json
```

Config structure:

```json
{
  "sites": {
    "example.com": {
      "server": "server-hostname-or-ip",
      "port": 65002,
      "username": "u123456789",
      "ssh_identity_file": "~/.ssh/hostinger_ed25519",
      "domain_path": "/domains/example.com/public_html",
      "description": "Main website"
    }
  },
  "default_settings": {
    "port": 65002,
    "username_pattern": "u[0-9]+"
  }
}
```

SSH key setup (recommended):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hostinger_ed25519
# Upload ~/.ssh/hostinger_ed25519.pub via hPanel → SSH Keys
```

Password file setup (fallback):

```bash
echo 'your-hostinger-password' > ~/.ssh/hostinger_password
chmod 600 ~/.ssh/hostinger_password
brew install sshpass   # macOS
sudo apt-get install sshpass  # Linux
```

## Commands

```bash
# Site management
./.agents/scripts/hostinger-helper.sh list
./.agents/scripts/hostinger-helper.sh connect example.com
./.agents/scripts/hostinger-helper.sh exec example.com 'ls -la'

# File transfer
./.agents/scripts/hostinger-helper.sh upload example.com ./dist/ /domains/example.com/public_html/
./.agents/scripts/hostinger-helper.sh download example.com /domains/example.com/public_html/ ./backup/

# Database
./.agents/scripts/hostinger-helper.sh exec example.com 'mysqldump -u username -p database_name > backup.sql'
```

## Security

- SSH key auth is recommended; set `ssh_identity_file` in site config (e.g. `~/.ssh/hostinger_ed25519`)
- Keep one credential per hosting account/server and reference it from every site on that account
- Do not put non-secret host, port, username, or domain-path metadata in the secret store
- Store passwords in files with 600 permissions; never commit them
- Port 65002 (non-standard); be aware of concurrent connection limits

Set web file permissions:

```bash
./.agents/scripts/hostinger-helper.sh exec example.com 'chmod 644 /domains/example.com/public_html/*.html'
./.agents/scripts/hostinger-helper.sh exec example.com 'chmod 755 /domains/example.com/public_html/scripts/'
```

## Troubleshooting

### WP-CLI limits on shared hosting

Observed with WP-CLI 2.12.0 and PHP 8.x: Hostinger shared hosting disables PHP CLI `proc_open()`/`proc_close()`. `wp plugin delete` calls `WP_CLI::launch()` to remove files through a subprocess, so it (and other commands that shell out) can fail with:

```text
Error: Cannot do 'launch': The PHP functions `proc_open()` and/or `proc_close()` are disabled. Please check your PHP ini directive `disable_functions` or suhosin settings.
```

`wp plugin deactivate` and `wp plugin install <zip> --force` can still work. For an authorized removal **keeping saved data**, back up first, verify the exact plugin folder and all plugin file basenames, and use WordPress's filesystem API without a subprocess. Replace `SLUG/SLUG.php` with the installed basename (check every plugin in the folder); never substitute an unchecked path. On multisite, verify inactivity on every child site and network-wide before deleting shared files; the guard below checks only the current site and network.

```bash
WP="$HOME/domains/<domain>/public_html"
wp --path="$WP" eval 'require_once ABSPATH . "wp-admin/includes/plugin.php";
require_once ABSPATH . "wp-admin/includes/file.php";
if (is_plugin_active("SLUG/SLUG.php") || is_plugin_active_for_network("SLUG/SLUG.php")) {
    WP_CLI::error("active, skipped");
}
if (!WP_Filesystem()) { WP_CLI::error("Filesystem initialization failed"); }
global $wp_filesystem;
if (!$wp_filesystem->delete(WP_PLUGIN_DIR . "/SLUG", true)) { WP_CLI::error("Deletion failed"); }
WP_CLI::success("Files deleted; uninstall routine not run");'
```

This bypasses uninstall hooks, preserving saved data rather than asking the plugin to erase it. When uninstall/data cleanup is explicitly wanted, use `delete_plugins(array("SLUG/SLUG.php"))` inside `wp eval` with the same includes and inactivity checks instead of `$wp_filesystem->delete(...)`. It runs registered uninstall routines, like the Plugins screen's Delete; inspect its return value with `is_wp_error()` and treat anything other than `true` as failure. Verify folder removal and site health afterwards. Plain `rm -rf` over SSH also works but bypasses WordPress and these guards; do not use it as an automatic fallback.

- **Account paths and logs**: One account SSH login covers its sites at `~/domains/<domain>/public_html`; inspect each site's `error_log` there.
- **Release ZIP updates**: `scp` the ZIP once to the account, run `wp --path="$WP" plugin install ~/plugin.zip --force` per intended site, verify the update, then remove the uploaded ZIP.
- **PHAR autoloader warnings**: `include(...vendor/composer/../psr/container/...): Failed to open stream` can be WP-CLI autoloader noise with plugins shipping prefixed vendors (observed with Kadence Pro 1.2.5), not proof of a broken install. Check the plugin's `vendor/vendor-prefixed/` files and the site's `error_log`, and verify site behavior before attempting a repair.
- **SQL queries**: `wp db query` fails with `Cannot do 'Process::run'`; use `global $wpdb;` inside `wp eval` instead. `wp db size` still works.

### Database backups without WP-CLI

`wp db export` also fails with `Cannot do 'Process::run'`. Call `mysqldump` directly with the site's own credentials, passed through the environment so the password never appears in output or the process list:

```bash
cd "$HOME/domains/<domain>/public_html"
export MYSQL_PWD="$(wp eval 'echo DB_PASSWORD;')"
mysqldump -h "$(wp eval 'echo DB_HOST;')" -u "$(wp eval 'echo DB_USER;')" \
  --single-transaction --no-tablespaces "$(wp eval 'echo DB_NAME;')" |
  gzip -c >"$HOME/backups/<domain>-db-<date>.sql.gz"
unset MYSQL_PWD
chmod 600 "$HOME/backups/<domain>-db-<date>.sql.gz"
zcat "$HOME/backups/<domain>-db-<date>.sql.gz" | grep -c 'CREATE TABLE'   # verify
```

**Connection refused**: Verify SSH is enabled on your plan, check hostname and port 65002, confirm password.

**Permission denied**: Username format is `u` followed by numbers (e.g. `u123456789`). Check password file has 600 perms and sshpass is installed.

**File upload issues**:

```bash
./.agents/scripts/hostinger-helper.sh exec example.com 'ls -la /domains/example.com/'
./.agents/scripts/hostinger-helper.sh exec example.com 'df -h'
```

## Deployment

```bash
# Build and deploy
npm run build
./.agents/scripts/hostinger-helper.sh upload example.com ./dist/ /domains/example.com/public_html/

# Verify
./.agents/scripts/hostinger-helper.sh exec example.com 'ls -la /domains/example.com/public_html/'
```

Backup before major changes:

```bash
DATE=$(date +%Y%m%d_%H%M%S)
./.agents/scripts/hostinger-helper.sh download example.com /domains/example.com/public_html/ ./backups/example.com_$DATE/
```
