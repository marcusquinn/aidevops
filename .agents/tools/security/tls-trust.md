---
description: Read-only local TLS trust-store canary checks
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
Fleet execution is a separate phase.

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
- Probes are read-only; never disable verification. Future fleet checks may target
  only owned, inventoried hosts. Probe reports must contain no secrets.
