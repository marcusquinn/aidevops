<!-- aidevops:brief-schema=v2 -->

# tls-trust phase 2: read-only fleet probes (hosts, containers, WordPress, shared-hosting PHP)

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `emudhra CA trust store fleet` → 1 hit; lessons are in the parent brief
- [x] Discovery pass: 0 PRs touch `tls-trust`; depends on phase 1 (GH#35278) `probe-script`
- [x] File refs verified: 3 refs checked, all present at HEAD
- [x] Tier: `tier:standard` — extends the phase-1 helper with an SSH fan-out that follows the `cloudron-helper.sh` probe pattern
- [x] Seeded draft PR decision recorded: skipped — depends on the phase-1 merge

## Origin

- **Created:** 2026-10-21
- **Session:** opencode:unknown-2026-10-21
- **Created by:** ai-interactive
- **Parent task:** t18748 (GH#35277). Blocked by: t18749 (GH#35278). Read the parent's "Context & Decisions" first.

## What

Add `fleet [--target NAME] [--format text|json]` to `.agents/scripts/tls-trust-helper.sh`. It is read-only and runs over SSH with `-o BatchMode=yes`, one target at a time. Run at most 2 parallel connections per shared-hosting account; Hostinger enforces connection limits.

1. **Targets.** Take them from existing inventories only, never from arguments that are not in an inventory:
   - Cloudron servers in `~/.cloudron.json`.
   - Hosts in `~/.config/aidevops/remote-hosts.json`.
   - `hosting_accounts` and `sites` in `~/.config/aidevops/site-inventory.json`.

   Skip any absent inventory file with an INFO line.
2. **Host checks (Linux, root or sudo optional).**
   - Pipe phase-1 `probe-script` into `ssh <host> sh -s -- <canary-url>`.
   - Report `ca-certificates` installed and candidate versions: `dpkg-query`, and `apt-cache policy` without `apt update`.
   - Flag `MIRROR-LAG` when `apt-cache policy` shows a newer version in `*-security` from `security.ubuntu.com` than the configured mirror. Report only; never change sources.
3. **Container checks.** When `docker` is available without a password prompt:
   - For each running container (`docker ps --format '{{.ID}} {{.Image}} {{.Names}}'`), run `docker exec <id> sh -s -- <url>`, passing the probe on stdin.
   - Group results by image, since containers sharing an image have the same answer.
   - Containers without `sh` → UNKNOWN.
   - When a `node:*`-derived image is TRUSTED, add a hint naming the `--use-openssl-ca` + `SSL_CERT_FILE` workaround (see parent).
4. **WordPress checks.** For each site path with `wp-config.php`:
   - Run `wp --path=<p> eval` and call `wp_remote_get(<canary>, ['timeout'=>15])`. `is_wp_error` with an SSL/certificate message → REJECTED; a response → TRUSTED.
   - If the `WP_HTTP_BLOCK_EXTERNAL`/`pre_http_request` short-circuit returns an error, report `BLOCKED-OUTBOUND` (neither safe nor exposed).
   - Also record the sha256 of `wp-includes/certificates/ca-bundle.crt`, so identical bundles are reported once.
5. **Shared-hosting PHP (no root).** Per PHP binary found at `/opt/alt/php*/usr/bin/php`, or `php` on PATH:
   - Probe raw `curl_init` with no `CURLOPT_CAINFO`, and the `file_get_contents` https stream.
   - Report `ini_get_all()` access levels for `curl.cainfo` and `openssl.cafile`.
   - When raw curl is TRUSTED and `curl.cainfo` access is `PHP_INI_SYSTEM` (4), classify as `HOST-CONTROLLED` with the hint "ask the host to update the system CA store". Do not report it as a fixable failure.
   - When streams are TRUSTED and `openssl.cafile` is `PHP_INI_PERDIR` (2), add the hint: per-site `.user.ini` `openssl.cafile=<patched bundle>` fixes streams only.
6. **Output.** One row per target × layer (host, container image, wp-site, php-binary) × canary. Exit 2 if any row is TRUSTED, otherwise 0. `HOST-CONTROLLED` and `BLOCKED-OUTBOUND` do not change the exit code but are listed in a summary.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The probe logic exists from phase 1 and the classifications are specified here; the work is SSH fan-out plus parsing, following `cloudron-helper.sh` → tier:standard.

## How

- SSH probe pattern: `.agents/scripts/cloudron-helper.sh:438-530`. The remote probe emits key=value lines and a local evaluator turns them into findings.
- Hostinger shell limits (no `crontab`, disabled `proc_open` on PHP 8.5, `/opt/alt/phpXX` layout): `.agents/services/hosting/hostinger.md` "PHP runtime" and the following section.
- Observed 2026-10-21 on one Hostinger account. Treat this as a regression expectation, not a universal rule: `curl.cainfo` access=4, `openssl.cafile` access=2. Raw PHP curl was TRUSTED. The stream wrapper was TRUSTED by default and REJECTED with `-d openssl.cafile=<patched WP bundle>`.

### Files Scope

- `.agents/scripts/tls-trust-helper.sh`
- `.agents/tools/security/tls-trust.md`

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/tls-trust-helper.sh
.agents/scripts/tls-trust-helper.sh fleet --format json | jq -e 'all(.[]; .result | IN("TRUSTED","REJECTED","UNKNOWN","HOST-CONTROLLED","BLOCKED-OUTBOUND"))'
.agents/scripts/linters-local.sh --changed
```

## Acceptance Criteria

- [ ] `fleet` covers host, container-image, wp-site and php-binary layers for every inventoried target that is reachable over BatchMode SSH, and lists unreachable targets as UNKNOWN with the reason.
- [ ] Negative: no write commands are sent to remote targets (`apt update/upgrade/install`, `sed -i`, `cp`, `mv`, `rm`, `tee`, `docker restart`, `wp option update`).

  ```yaml
  verify:
    method: codebase
    pattern: "(apt(-get)? (update|upgrade|install)|sed -i|docker (restart|stop|rm)|wp option update)"
    path: ".agents/scripts/tls-trust-helper.sh"
    expect: absent
  ```

- [ ] A shared-hosting PHP binary with raw curl TRUSTED and `curl.cainfo` access 4 reports `HOST-CONTROLLED`, not TRUSTED, and does not by itself produce exit 2.
- [ ] `shellcheck` is clean, and `linters-local.sh --changed` passes.
