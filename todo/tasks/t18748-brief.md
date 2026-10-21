<!-- aidevops:brief-schema=v2 -->

# Parent: `aidevops security tls-trust` — data-driven client trust-store checks (local + fleet)

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `emudhra CA trust store fleet` → 1 hit — eMudhra response lessons (2026-10-21), folded into Context below
- [x] Discovery pass: 0 open/merged PRs touching `tls-trust`; related advisory issue GH#35271 (static advisory only)
- [x] File refs verified: 6 refs checked, all present at HEAD
- [x] Tier: `tier:thinking` parent — decomposition only; children carry implementation
- [x] Seeded draft PR decision recorded: skipped — parent task

## Origin

- **Created:** 2026-10-21
- **Session:** opencode:unknown-2026-10-21
- **Created by:** ai-interactive
- **Conversation context:** During the eMudhra intermediate-CA compromise response, every exposure check had to be improvised by hand: the Mac's curl, Node and Python; 5 Ubuntu hosts; 92 containers; 17 WordPress installs. The maintainer approved making this a reusable `aidevops security` capability.

## What

A data-driven `aidevops security tls-trust` capability:

1. **Local:** probe each installed TLS client against a canary list of known-bad-chain test URLs, and report TRUSTED / REJECTED / UNKNOWN per client.
2. **Fleet (read-only, SSH):** the same probes on owned hosts, inside their running containers, and through the WordPress HTTP API of each inventoried site. Also report pending security updates for `ca-certificates`, including mirror lag.
3. **Advisory linkage:** an advisory file can name a check. `aidevops security` runs that check and auto-dismisses the advisory once every probed client rejects the canary.

The next CA/trust-store incident should need only a new canary line plus an advisory file, not new code.

## Why

`aidevops security` today covers posture, secret hygiene and npm supply chain. It has no check for client trust stores, host package security state, or container and app-bundled CA stores. Those were the whole attack surface in this incident, and nothing in the framework would have told users they were still exposed.

## Phases

- Phase 1 - local probe helper, canary config, `aidevops security tls-trust` wiring [auto-fire:on-prior-merge]
- Phase 2 - fleet probes over SSH (hosts, containers, WordPress, pending security updates) [auto-fire:on-prior-merge]
- Phase 3 - advisory → check linkage with auto-dismiss on verified clean

### Files Scope

- `.agents/scripts/tls-trust-helper.sh`
- `.agents/configs/tls-trust-canaries.conf`
- `.agents/tools/security/tls-trust.md`
- `aidevops.sh`
- `.agents/scripts/aidevops-update-check.sh`
- `.agents/advisories/emudhra-ca-compromise-2026-10.advisory`

## Context & Decisions (shared by all children)

Lessons observed on 2026-10-21; children must encode them:

- **Node:** Homebrew Node uses the Homebrew OpenSSL store, so it is fixed by `brew upgrade ca-certificates`. Official Node binaries and `node:*` Docker images use a compiled-in root store, so updating system `ca-certificates` does not fix them.
- **Node workaround:** `--use-openssl-ca` plus `SSL_CERT_FILE` fixes official Node. `--use-system-ca` does not: it adds the system store to the bundled roots.
- **Busybox:** `wget` results must be classed UNKNOWN, never TRUSTED/REJECTED.
- **Stores are per artifact:** each Docker container, WordPress install (`wp-includes/certificates/ca-bundle.crt`) and Electron app has its own CA store. Host patching does not cover them.
- **macOS curl:** `/usr/bin/curl` reads `/etc/ssl/cert.pem`, which Apple did not update; Homebrew curl is keg-only (`/opt/homebrew/opt/curl/bin/curl`).
- **Mirror lag:** the Hetzner Ubuntu mirror lagged the `ca-certificates` security update while `security.ubuntu.com` had it. Compare candidate versions against the upstream security pocket.
- **Shared hosting:** with no root, server-level PHP curl is outside the account's control. Report it as `host-controlled`, not as a fixable failure.
- **Hard boundaries:** probes are read-only. Never disable TLS verification to "work around" a failure. Fleet probes go only to inventory-listed hosts the user owns. Probe output carries no secrets.

## Relevant Files

- `aidevops.sh:1764` `_cmd_security` — subcommand dispatch and the no-arg full assessment
- `.agents/scripts/supply-chain-advisory-helper.sh` — helper pattern (scan / startup-check / dismiss)
- `.agents/scripts/cloudron-helper.sh:438-530` — remote SSH probe emitting key=value lines plus an evaluator
- `.agents/scripts/aidevops-update-check.sh:373` `_check_advisories` — session advisory surfacing
- `~/.config/aidevops/site-inventory.json` (`hosting_accounts.*.ssh_*`, `sites.*.hosting.deployment_path`), `~/.cloudron.json`, `~/.config/aidevops/remote-hosts.json` — fleet inventories
- `.agents/advisories/` — advisory files (GH#35271 adds the eMudhra one)
