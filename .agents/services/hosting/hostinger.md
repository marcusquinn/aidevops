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

### hPanel cron jobs

SSH on shared hosting has no `crontab`; that is expected, not a blocker. Use the API-backed helper:

```bash
hostinger-helper.sh cron list   --ssh <account-alias> [--json]
hostinger-helper.sh cron create --ssh <account-alias> --time '<cron>' --command '<cmd>' [--apply]
hostinger-helper.sh cron delete --ssh <account-alias> --uid <uid> [--apply]
hostinger-helper.sh cron output --ssh <account-alias> --uid <uid>
```

The account name comes from `ssh <alias> whoami` and the token is injected from the secret store. `create` and `delete` preview unless `--apply` is given. Each change first writes a 0600 snapshot of the job list to `~/.aidevops/.agent-workspace/work/hostinger-cron/` and then prints the list again. `delete` removes only the given UID. After a failed or partial response the live list is printed; inspect it before any retry. Home paths are masked in output. See `hostinger-wordpress-cron.md`.

### Lifetime SSL behind Cloudflare

Observed **2026-10-25/26**: a new site behind a proxied Cloudflare wildcard stayed at `waiting_for_retry` with `last_error: "Domain challenge failed"`; Full (strict) returned 525. Even a reachable HTTP challenge token did not prove Hostinger could issue the certificate. Hostinger's challenge checks expect the hostname to resolve to the hosting origin IP, not Cloudflare's proxy IPs.

For an authorised DNS recovery (not performed by the helper):

1. Record the existing DNS state and privately verify the Hostinger origin IP. Add temporary **DNS-only** A records for the exact site hostname (for example `site.example.com`) and its `www` name (`www.site.example.com`), pointing at that origin. Use TTL 60 where supported and a unique comment identifying this SSL recovery. Do not replace an existing explicit record without a separately reviewed restoration plan; exposing the origin bypasses Cloudflare protection during this interval.
2. Wait for DNS propagation and Hostinger's automatic retry; inspect `hostinger-helper.sh ssl-status site.example.com`. Certificates issued within 2–15 minutes in these observations, not a guaranteed retry interval. `POST .../ssl/setup` returns 422 while status is `installing` or `waiting_for_retry`: it cannot force a retry. Use the retry timer or hPanel **Cancel → Install SSL**, not DELETE or repeated setup calls.
3. Before restoring the proxy, verify the origin certificate privately with `openssl s_client -connect <origin-IP>:443 -servername site.example.com -verify_hostname site.example.com -verify_return_error </dev/null`. Check successful chain/hostname verification, issuer and expiry; do not publish the origin IP or raw output.
4. Delete **only** the temporary records identified by their saved IDs and recovery comment, restoring the original wildcard/proxy behaviour. Do not delete or change the wildcard. Verify HTTPS through Cloudflare returns the expected site under Full (strict). If issuance is still pending, keep an explicit recovery checkpoint rather than silently leaving DNS-only records behind.

### Detect copied or restored WordPress sites

hPanel can report `website_type: other` and omit WordPress tools/WP Admin until a detection scan runs. `hostinger-helper.sh wordpress-detect example.com` resolves the account from the exact website, queues the non-destructive, idempotent `POST /api/hosting/v1/accounts/{username}/wordpress/installations/detect`, then polls `GET /api/hosting/v1/wordpress/installations` filtered by account/domain. This scans the **whole account**, not only that domain; it does not install, import or overwrite WordPress. Stdout contains only matching `id`, `domain`, `is_valid` metadata (the API's `valid` field is normalised to `is_valid`). An existing installation may return immediately; that is not proof the new scan finished. Polling stops after 12 checks spaced 5 seconds apart, with each request limited to 10 seconds; timeout/API errors exit nonzero. If absent, inspect hPanel or query again with `api`; never reinstall as a fallback.

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

**CA trust stores (observed 2026-10-21, during a CA-compromise response).** Shared-hosting PHP has three separate trust paths.

- **WordPress HTTP API:** uses each install's `wp-includes/certificates/ca-bundle.crt`. The account can edit this file, but a core update replaces it.
- **Raw PHP `curl_init` without `CURLOPT_CAINFO`:** uses the host bundle, `/opt/alt/openssl11/etc/pki/tls/cert.pem`. `curl.cainfo` is `PHP_INI_SYSTEM` (access level 4 from `ini_get_all()`), so only Hostinger can fix this path. Report it as host-controlled and ask support to escalate to a server administrator.
- **PHP HTTPS streams (`file_get_contents`, `fopen`):** honour `openssl.cafile`, which is `PHP_INI_PERDIR`. LiteSpeed web PHP ignored it in `.user.ini`, even after the 300 s cache TTL. It took effect as `php_value openssl.cafile "<absolute path>"` inside `<IfModule LiteSpeed>` in `.htaccess`, verified through a temporary web PHP probe.

Pin a copy stored outside `wp-includes`, add the block between marker comments so it can be removed exactly, and record a task to remove it once the host is patched. A frozen bundle misses future root changes.

#### Security releases

Observed on **2026-10-21** during the PHP RCE release (advisory `php-rce-2026-10`); recheck per account. Playbook: `tools/runtime/php-server-admin.md` "Security Releases".

- **Builds are host-controlled.** Every site on a PHP version runs the shared `/opt/alt/phpXX` build; the account cannot update it. Check each version with `/opt/alt/php85/usr/bin/php -r 'echo PHP_VERSION, " upload_progress=", ini_get("session.upload_progress.enabled"), PHP_EOL;'` (repeat for 82–84). Patched builds had not shipped hours after the upstream release, so ask support for an ETA.
- **The host may mitigate first.** Hostinger set `session.upload_progress.enabled = Off` in each `/opt/alt/php8x/etc/php.ini` the same morning, before patched builds. Read the setting before adding a per-site override.
- **Per-site overrides that took effect** for web PHP, verified with a temporary probe: `php_value post_max_size`, `upload_max_filesize` and `fatal_error_backtraces` inside `<IfModule LiteSpeed>` in the site's `.htaccess`, prepended between BEGIN/END markers with a backup of each file. The default 12288M limits otherwise stay in force.
- **Check uploads before lowering limits.** Sites holding legitimate uploads above the new limit (videos, large images) keep their limit and receive only the non-upload settings.
- **Per-site PHP version over the API.** Read `GET /api/hosting/v1/accounts/{username}/websites/{domain}/php/details` (`php_version`, `php_version_full` is the exact shared build, `php_versions.supported`). Change it with `PATCH .../php/version` and `{"version":"8.5"}`. Take `{username}` from `GET /api/hosting/v1/websites?domain=<domain>` in the same command. `hostinger-helper.sh api [METHOD] ENDPOINT [JSON]` injects the token from the secret store. Observed: switching five WordPress sites from 8.3 to 8.5 kept status codes and response sizes, and per-site `.htaccess` mitigations stayed in force. Switching does not patch anything while every build on the host is unpatched; compare `php_version_full` with the fixed versions. Before switching, back up `.htaccess`, record status and size for representative pages, then check them and `error_log` afterwards.
- **SSL status over the API.** Run `hostinger-helper.sh ssl-status <domain>`: it resolves `{username}` from `GET /api/hosting/v1/websites?domain=<domain>` (`.data[0].username`), then prints the JSON from `GET /api/hosting/v1/accounts/{username}/websites/{domain}/ssl/status`. Both requests are GET-only; caller-side command substitution is unnecessary. Observed on **2026-10-25**: fields include `status` (`active`, `waiting_for_retry`), `provider` (`hssl`), `is_lifetime`, `is_https_redirect_enabled`, `expires_at` and `last_error` (for example `Domain challenge failed`). The sibling `/ssl` route is DELETE-only; GET is rejected with `Supported methods: DELETE`. Do not use DELETE to diagnose or guess an SSL setup/retry route. An addon domain behind a proxied Cloudflare wildcard returned `waiting_for_retry` while siblings on the same proxied IPs had active Let's Encrypt (`hssl`) certificates; the missing plain-HTTP `/.well-known/acme-challenge/<missing>` path returned 404 without a redirect, so this alone does not identify the challenge failure. To inspect the origin certificate for a Cloudflare 525 without publishing the origin IP, run from the server: `curl -skv --resolve <host>:443:<own-public-IP> https://<host>/` and read `subject`, `issuer` and `expire date`. Keep the IP and raw verbose output private; `-k` permits inspection but does not prove certificate trust.

Dated uploads directories returned 403 in this observation. Verify directory-listing protection per site rather than assuming it applies to every account. For the read-only baseline, worker/memory sizing, OPcache assessment, host boundaries, and safe directory-listing remediation, read `tools/runtime/php-server-admin.md`.

### Read-only audit notes

Observed on shared hosting from **2026-10-14** (later observations are dated); recheck per account rather than treating these as universal plan defaults.

- **Jailed shell**: No `/dev/fd`; Bash process substitution (`< <(...)`) fails with `/dev/fd/62: No such file or directory`. Use pipes or variables in scripts copied to the host.
- **Missing commands**: `crontab` and `rpm` are unavailable; `convert`, `magick` and `ldd` are not on PATH, and there are no `phpX.Y` commands. `/etc/os-release` is not readable. Cron jobs live in hPanel. The default `php` is the account's PHP; every available build (5.2–8.5 observed) is at `/opt/alt/phpXX/usr/bin/php`. Answer support's Imagick version check with those paths, for example `/opt/alt/php83/usr/bin/php -r 'echo Imagick::getVersion()["versionString"], PHP_EOL;'`. PHP 5.2 and 5.3 cannot run this one-liner because they lack function array dereferencing.
- **Disabled PHP functions**: The list is set per PHP version (CloudLinux PHP Selector options in `~/.cl.selector/alt_phpXX.cfg`), so check each version a site runs, for example `/opt/alt/php83/usr/bin/php -r 'echo ini_get("disable_functions"), PHP_EOL;'`. Observed: PHP 8.5 (the shell default) disabled both `shell_exec()` and `proc_open()`; PHP 8.3 on the same account disabled `shell_exec()` but not `proc_open()`. Without `proc_open()`, `wp db query` fails; calling a disabled function in `wp eval` ends in WordPress's “critical error” message.
- **Other PHP options**: the same files held `expose_php=On`, so every PHP response's `X-Powered-By` header names the exact PHP version, and `upload_max_filesize` and `post_max_size` of `12288M`, which WordPress uses as its upload limit unless something lowers it (`upload_size_limit` filter).
- **Shared image library**: Every available PHP build (5.2–8.5) loads the same ImageMagick library (7.1.2-31 observed, then 7.1.2-34 from 2026-10-25). Switching PHP does not change it; only Hostinger can update it. Chat support first said it could not be updated on a Cloud plan and suggested a VPS. After a written security escalation listing the advisories, Hostinger installed 7.1.2-34 nine days later; on 2026-10-29 CloudLinux's changelog still listed that build (`alt-ImageMagick` 7.1.2-34.1) as beta. To see which fixed builds exist, read CloudLinux's package changelog, for example `curl -sS https://changelog.cloudlinux.com/api/packages/alt-ImageMagick | jq -r '.versions[:3][] | "\(.released_at) \(.version) \(.channels)"'` (JSON; the same API answers for `alt-openssl11`, `alt-libxml2` and `alt-curlssl11`). Turning `imagick` off is not per website, whether in hPanel's PHP Configuration or with `PATCH /api/hosting/v1/accounts/{username}/websites/{domain}/php/extensions` and `{"disable":["imagick"]}`: observed extension changes applied to every website on the account using the same PHP version, and those websites read the same `php.ini`. Once, a website that had just changed PHP version lacked an extension that the others on that version had. So list the websites on that version and decide for all of them, then check each one (`GET .../websites/{domain}/php/details`, or a temporary web PHP file). WordPress then uses GD; the observed GD builds on PHP 8.1+ support WebP and AVIF. To keep one WordPress site off ImageMagick without touching the others, filter `wp_image_editors` to GD editors only, optionally only for users who cannot `upload_files`; direct `new Imagick()` calls in plugins are not covered. Ghostscript is `/usr/bin/gs` (9.27 observed, unchanged by the ImageMagick update) and used through Imagick for PDF thumbnails; check with `/usr/bin/gs --version`. Without `rpm`, ask the host whether the package carries later security fixes. Checks (observed, recheck per account; all read-only):
  - **Ghostscript fix status**: the same CloudLinux changelog API answers for `ghostscript`, but on 2026-10-30 listed only el7/TuxCare ELS builds, not el8. Its CVE-2026-101258 fix in `ghostscript-9.25-5.0.1.el7.tuxcare.els3` (2026-10-21) does not establish CloudLinux 8's fix status. Check the affected-packages table on [Red Hat's CVE page](https://access.redhat.com/security/cve/CVE-2026-101258): it lists RHEL 8 `ghostscript` as fixed by RHSA-2026:83552, released 2026-10-15. This does not establish the installed CloudLinux package's fix status; ask the host which fixes it carries. Recheck the API and vendor status for each advisory.
  - **Which ImageMagick**: `/opt/alt/php85/usr/bin/php -r 'print_r(Imagick::getConfigureOptions("CONFIGURE_PATH"));'` prints its configuration folder (observed `/opt/alt/alt-ImageMagick/etc/ImageMagick-7/`, the `alt-ImageMagick` package). Older `imagick` builds lack `getConfigureOptions()`.
  - **Security policy**: read `policy.xml` in that folder. Observed: no active rules, only `<policy domain="Undefined" rights="none"/>` (ImageMagick's open policy), so PDF, PS, EPS, XPS, MVG and MSL are all enabled and PDFs go to Ghostscript. Ask the host whether a restrictive policy can cover the time before an update. The 7.1.2-34 update kept the same open policy.
  - **Package file timestamps without `rpm`**: `stat -c '%n built %y ctime %z' /usr/bin/gs /opt/alt/alt-ImageMagick/etc/ImageMagick-7/policy.xml`. rpm keeps each file's build-time date as its modification time; `ctime` is the last status change, so treat it as approximate installation evidence only (a later permission or ownership change updates it). Observed: Ghostscript 9.27 built 2026-10-06 and installed 2026-10-13; ImageMagick 7.1.2-34's `policy.xml` built 2026-10-20 and installed 2026-10-25 18:54 UTC, three minutes before the `lsphp` builds with PHP 8.3.36 and 8.5.12. A recent build date suggests a rebuild with backported fixes; the host must confirm the release.
  - **Libraries without `ldd`**: in PHP, read `/proc/self/maps` and keep paths matching `libgd|libavif|libwebp|libMagick`, for example `/opt/alt/php85/usr/bin/php -r 'preg_match_all("~/\S*(?:libgd|libavif|libwebp|libMagick)\S*~", file_get_contents("/proc/self/maps"), $m); print_r(array_unique($m[0]));'`. Observed GD libraries were under `/opt/alt/libgd` and `/opt/alt/libwebp`.
  - **Who can reach it**: audit public sign-ups and front-end uploads with [Image-library advisories: who can reach it](../../tools/wordpress/wp-admin.md#image-library-advisories-who-can-reach-it) before choosing a targeted mitigation.
  - **GD trade-off**: with `imagick` disabled, WordPress (7.1 observed) still makes JPEG, PNG, GIF, WebP and AVIF sizes on GD 2.3.3. It stops making PDF thumbnails and converting HEIC uploads, and GD drops embedded colour profiles.
- **Libraries linked into PHP**: `/opt/alt/php85/usr/bin/php -r 'echo OPENSSL_VERSION_TEXT, " | curl ", curl_version()["version"], " | libxml ", LIBXML_DOTTED_VERSION, PHP_EOL;'`, and the same for each PHP version in use. Observed on PHP 8.3 and 8.5: OpenSSL 1.1.1w (the last public 1.1.1 release; upstream support ended in September 2023), curl 8.22.0 linked to it, libxml2 2.10.2, ICU 71.1 and zlib 1.2.11. A version string does not show backported fixes. PHP loads them from CloudLinux's maintained `alt-openssl11`, `alt-curlssl11` and `alt-libxml2` packages (`/opt/alt/openssl11`, `/opt/alt/curlssl11` and `/opt/alt/libxml2`; match `libssl|libcurl|libxml2` in the "Libraries without `ldd`" check above). The `alt-openssl11` changelog lists backported CVE fixes, for example CVE-2026-45447 in 1.1.1w-3.4 (2026-06-12), so read it before treating 1.1.1w as unpatched. The changelog can lag: on 2026-10-29 the host's libxml2 was built 2026-10-20, but the latest `alt-libxml2` build listed was from 2025-01-30. When they differ, ask the host which release is installed. WPVulnerability's server checks cover PHP, the web server, the database, ImageMagick, curl, Memcached, Redis and SQLite, not OpenSSL, libxml2 or Ghostscript. Hiding a component in its settings, or with a `WPVULNERABILITY_HIDE_*` constant, also stops WPVulnerability checking it (5.1.6, `wpvulnerability_get_vulnerabilities_clean()`), so the stored count keeps its value from when it was hidden: ImageMagick still read 35 after the host moved to 7.1.2-34. Judge a hidden component by its version and the advisories.
- **Site PHP builds**: hPanel's per-website PHP version is not readable from the shell. To see the builds serving sites right now, run `pgrep lsphp | xargs -r -I{} readlink /proc/{}/exe | sort | uniq -c`, which counts the `lsphp` workers per executable (for example `/opt/alt/php85/usr/bin/lsphp`), and `/opt/alt/php85/usr/bin/lsphp -v` for that build's version. After a host update, a worker still running the replaced build shows `(deleted)` after the path; none did on 2026-10-29, four days after the 2026-10-25 update. Idle sites may have no worker at that moment.
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

`api`, `fleet` and `cron` need no config file: they use `HOSTINGER_API_TOKEN` from the secret store. The site commands (`list`, `connect`, `exec`) still need the legacy config, read from `configs/hostinger-config.json` beside the scripts directory or from `HOSTINGER_CONFIG_FILE`. Copy the template and edit it with server details:

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

For fleet core minor releases, use the [core-minor workflow](../../tools/wordpress/wp-cli-reference.md#core-minor-releases-across-ssh-installs).
It calls `mysqldump` with a temporary 0600 defaults file and stores dumps outside
the web root before applying a SHA1-verified locale package. Filtered WordPress
HTTP can make `wp core update --minor` falsely report "latest"; this workflow
queries the release API outside WordPress and verifies the installed version,
checksums and home/login probes. It never applies major releases or rolls back
automatically. Remote Python 3.9+ is required; the dump uses `--single-transaction`,
so the site's own per-database grants suffice.

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
