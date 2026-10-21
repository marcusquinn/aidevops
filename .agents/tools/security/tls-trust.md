---
description: Read-only local and inventoried fleet TLS trust-store canary checks
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# TLS trust checks

Run `aidevops security tls-trust` (defaults to `local`), or
`aidevops security tls-trust local --canary emudhra-2026-10-direct --format json`.
The full `aidevops security` assessment also runs these checks.

Canaries live in `configs/tls-trust-canaries.conf`, one
`id|url|incident|added` row per HTTPS endpoint; blank lines and `#` comments
are ignored. Every canary must have a known-bad chain: rejection is expected.
Add canaries only from trusted incident evidence, never arbitrary untrusted URLs.

- `TRUSTED`: TLS succeeded (any HTTP status); this client is exposed.
- `REJECTED`: the client reported a certificate/TLS rejection.
- `UNKNOWN`: network failure, timeout, unavailable capability or unsupported client.
  This is **not** evidence of safety. BusyBox wget is always UNKNOWN; other wget
  implementations are currently unsupported too.
- Exit 2 means at least one TRUSTED client, 0 means none TRUSTED (including
  UNKNOWN), and 1 means invalid usage/configuration. JSON requires jq and is an
  array with client, executable, canary, URL, incident, result and remediation.

Local checks cover system curl, PATH curl, keg-only Homebrew curl, Node, Python,
PHP and PATH wget when present. Distinct curl discovery entries remain visible
even when they resolve to the same binary. Probes retain certificate verification,
do not follow redirects, send no credentials, and use a 15-second probe timeout.
curl configuration files are ignored. No packages or trust stores are modified.

`tls-trust-helper.sh probe-script` emits a self-contained POSIX sh script taking
an HTTPS URL as its first argument. It chooses curl, Node, Python, then wget,
and prints exactly `client TRUSTED|REJECTED|UNKNOWN`. Local checks execute this
same body with a selected client and executable, preventing classification drift.

## Advisory verification

An advisory's first line remains its human summary. An optional later line links
it to a check, for example:

```text
# check: tls-trust local --canary emudhra-2026-10-direct
```

The no-argument `aidevops security` assessment checks each undismissed advisory
with this metadata. Only `tls-trust local` and `tls-trust local --canary ID` are
allowlisted, mapped to the fixed `tls-trust-helper.sh` helper. Arguments are literal
whitespace-separated tokens, not shell code; quoting and expansion are unsupported.
Unknown checks stay active. Advisories without metadata behave as before.

Exit 0 appends the advisory ID to `~/.aidevops/advisories/dismissed.txt` and prints
`auto-dismissed <id>: verified clean`. This follows the helper's **no TRUSTED client**
contract, not proof that all clients were REJECTED: UNKNOWN results can still be
present and must not be treated as evidence of safety. Exit 2 retains the advisory
and displays the helper's TRUSTED rows and remediation hints. Other failures also
retain the advisory. Session startup only displays the first-line summary; it
never runs advisory checks or displays check metadata.

## Fleet checks

Run `aidevops security tls-trust fleet --format json`, or restrict the inventory
name with `fleet --target NAME`. Fleet mode requires local Python 3; remote hosts
need POSIX sh, not Python. JSON is an array; INFO messages and result counts go to
stderr so stdout remains machine-readable. Empty inventories produce `[]`, not a
claim that a fleet was verified. Missing inventory files are reported and skipped.

Targets come only from `~/.cloudron.json` (`servers`),
`~/.config/aidevops/remote-hosts.json` (`hosts`, SSH transport), and
`~/.config/aidevops/site-inventory.json` (`hosting_accounts` with referenced
`sites.*.hosting.deployment_path` and child deployment paths). The target option
filters names; it never accepts an arbitrary SSH address. Inventory credentials
are not read or printed. SSH uses existing key/agent authentication, BatchMode,
a 15-second connection timeout and normal host-key verification. All connections
are serial (at most one per shared-hosting account). Each target/canary execution
has a 240-second budget; exhausted budgets and unreachable targets are UNKNOWN.

Rows identify target, layer, artifact, client, canary, URL, incident and result:

- `host`: installed curl, Node, Python and unsupported wget use the phase-1
  probe body. `ca_certificates` records installed/candidate versions and available
  mirror/security versions from the existing apt cache. Remote dpkg version
  ordering flags `mirror_lag` / `MIRROR-LAG` when a version from
  `security.ubuntu.com` in a `*-security` pocket is newer than all configured
  mirror versions. No cache refresh or source edits occur. Missing cache data
  cannot establish that mirrors are current.
- `container-image`: probes each running container using `docker exec -i`, with
  no sudo/password prompt. Node is preferred when present, to check bundled
  roots rather than only a system curl store. Other containers use phase-1 client
  selection. Images group observations while retaining each container ID/name;
  exposure or uncertainty is never hidden by a rejecting sibling. Missing sh or
  inaccessible Docker is UNKNOWN. TRUSTED Node results include the
  `--use-openssl-ca` plus `SSL_CERT_FILE` workaround.
- `wp-site`: inventoried paths with `wp-config.php` use WP-CLI `wp_remote_get`
  with timeout 15 and redirects disabled. Outbound policy blocks and plugin
  `pre_http_request` short-circuits are `BLOCKED-OUTBOUND`, not proof of TLS
  rejection or exposure. Missing config/WP-CLI is UNKNOWN. SHA-256 bundle hashes
  group identical `wp-includes/certificates/ca-bundle.crt` observations within a
  target/canary; per-site results remain in `observations`. Missing hashes are
  not grouped as identical bundles.
- `php-binary`: `/opt/alt/php*/usr/bin/php` and PATH PHP each check raw curl
  (without a CAINFO override) and HTTPS streams. JSON details record the access
  level of `curl.cainfo` or `openssl.cafile`. Raw curl TRUSTED with access 4 is
  `HOST-CONTROLLED`: ask the host to update the system CA store. Stream TRUSTED
  with access 2 includes the per-site `.user.ini` `openssl.cafile` hint, which
  fixes streams only. No PHP settings are changed.

Only TRUSTED rows produce exit 2. HOST-CONTROLLED and BLOCKED-OUTBOUND remain
visible in rows and the stderr summary but do not themselves change the exit
code. UNKNOWN is never a clean-bill-of-health assertion. Grouped rows retain
their individual observations because images and bundles can have different
runtime overrides. Probes never remediate: they do not change packages, files,
containers, WordPress settings or TLS verification.

## Incident lessons (2026-10-21)

- Homebrew Node uses Homebrew OpenSSL roots: update `ca-certificates` and Node.
  Official Node and `node:*` images have bundled roots; system updates are insufficient.
- For official Node, upgrade Node or use `--use-openssl-ca` plus `SSL_CERT_FILE`
  pointing at a patched bundle. `--use-system-ca` adds roots rather than replacing them.
- BusyBox wget cannot reliably attest verification; report UNKNOWN.
- Containers, Electron apps and WordPress (`wp-includes/certificates/ca-bundle.crt`)
  have artifact-specific stores; patching the host does not cover them.
- macOS `/usr/bin/curl` reads Apple's `/etc/ssl/cert.pem`; Homebrew curl is keg-only.
  Consult the canary incident URL for Apple store remediation.
- Package mirrors may lag: compare CA package candidates with the upstream security
  pocket (observed with the Hetzner Ubuntu mirror versus `security.ubuntu.com`).
- Shared-hosting PHP curl is host-controlled; request the provider's update.
- Probes are read-only; never disable verification. Fleet checks may target
  only owned, inventoried hosts. Probe reports must contain no secrets.
