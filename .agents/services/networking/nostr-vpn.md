---
description: Nostr VPN/FIPS - experimental accountless mesh VPN using Nostr identities
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Nostr VPN / FIPS - Experimental Mesh Networking

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Experimental decentralized mesh VPN for advanced users who want accountless, Nostr-key-based device networking.
- **Use when**: Connect laptop, workstation, homelab, VPS, and remote compute devices without SaaS coordination.
- **CLI**: `fips`, `fipsctl`, `fipstop`, `fips-gateway`; aidevops wrapper: `.agents/scripts/nostr-vpn-helper.sh`.
- **Docs/source**: https://nostrvpn.org/ · https://github.com/jmcorgan/fips · https://git.iris.to/#/npub1xdhnr9mrv47kkrn95k6cwecearydeh8e895990n3acntwvmgk2dsdeeycm/nostr-vpn
- **Status**: Experimental; upstream says protocol/API are not stable and security audit is pending. macOS `v0.4.0-rc1` packages are available for testing and must pass checksum plus package-structure validation before install.
- **Secrets**: Use `aidevops secret set FIPS_NSEC` only for import/recovery; never paste Nostr private keys into chat or commit key files.

**Key concepts**: Nostr keypair identity · npub node address · FIPS mesh · IPv6 `fd00::/8` TUN · `.fips` DNS · Nostr-mediated discovery · peer ACL · optional `fips0` firewall · LAN gateway · WireGuard exit sidecar.

<!-- AI-CONTEXT-END -->

## Decision Guidance

Use **Nostr VPN/FIPS** when self-sovereign identity and no central control plane matter more than mature administration. Use **NetBird** for teams, SSO, API-managed ACLs, policy UX, and production support. Use **Tailscale** for fastest onboarding where SaaS control-plane dependency is acceptable.

Do not present FIPS as the default aidevops networking layer until upstream protocol stability and security audit status improve.

Do not present FIPS as “full anonymity” or “no spying possible”. It reduces dependence on a SaaS control plane, but relays, transport endpoints, timing, IPs, and compromised devices can still leak metadata.

## aidevops Use Cases

- Secure SSH and OpenCode server access between personal devices across networks.
- Reach workstation/GPU/storage resources from laptop without exposing public ports.
- Build a self-hosted mesh spanning homelab, VPS, mobile, and travel devices.
- Run aidevops helpers on one node while using compute or services on another.
- Test resilient routing over UDP, TCP, Ethernet, Tor, or Bluetooth transports.
- Keep private admin paths for Git remotes, MCP services, dashboards, staging apps, backup/storage nodes, and CI/debug workers bound to loopback or FIPS-only addresses.

## Privacy and Anonymity Best Practices

Use FIPS as a private device mesh, not as a standalone anonymity network:

1. Generate fresh per-device FIPS/Nostr identities; never reuse a public/social Nostr npub.
2. Separate identities by purpose: personal devices, experiments, client/work, travel, and high-risk research.
3. Prefer self-hosted or trusted private Nostr relays for discovery. If public relays are used, assume they can observe npubs, IPs, timestamps, and discovery metadata even when payload contents are encrypted.
4. Keep peer ACLs explicit and default-deny. Treat default-open ACL state as unsafe for exposing SSH, OpenCode, MCP, dashboards, or gateways.
5. Disable LAN gateway, exit-node, and broad listener modes unless the trust boundary is documented and reviewed.
6. Bind services to loopback or the FIPS interface only; do not publish public listeners as a shortcut.
7. Keep FIPS disabled when no trusted peer is ready; enable only for an intentional test window.
8. Rotate identities after suspected compromise and remove stale peers from ACLs, known-hosts, and local host maps.

For stronger privacy, combine FIPS with other aidevops guidance and tools:

- `tools/security/opsec.md` — threat modelling, DNS privacy, device hygiene, identity compartmentalisation, anti-fingerprinting browsers, and incident response.
- `services/communications/privacy-comparison.md` — choose SimpleX or Signal for private human messaging; do not use FIPS as a chat privacy substitute.
- Tor or a reputable no-logs VPN — hide source IP from relays/transports where the threat model requires it.
- Self-hosted Nostr relay — reduce third-party relay metadata exposure.
- FileVault/LUKS/BitLocker, YubiKey-backed SSH/FIDO2, EXIF stripping, separate browser profiles, CamoFox, or hardened Firefox/Arkenfox — reduce endpoint and identity-correlation risk.

Hard limit: full privacy and anonymity cannot be guaranteed by a VPN overlay alone. IP addresses, timing correlation, device fingerprints, writing style, payment trails, relay logs, and compromised endpoints can identify users.

## Setup Pattern

1. Install FIPS from a pinned upstream release or package; verify checksums first.
2. On macOS, prefer `v0.4.0-rc1` or later packages over the removed corrupt `v0.3.0` package.
3. For every macOS package, including source-built packages, verify integrity with checksum comparison, `pkgutil --payload-files`, `pkgutil --expand`, and `xar -tf`; do not install packages that fail these checks. `pkgutil --check-signature` may report `no signature` for unsigned upstream release candidates; treat that as an unsigned-package warning, not as proof of corruption.
4. Generate a persistent identity on each device, or import one from `aidevops secret set FIPS_NSEC` during recovery only.
5. Record device **npubs**, labels, and intended roles in local config; never store private keys in git.
6. Configure peer ACLs before joining wider meshes.
7. On macOS, a successful install may start a root LaunchDaemon immediately. If no trusted peer is ready, stop and disable it after validation.
8. Enable the optional `fips0` firewall baseline before exposing services.
9. Test `.fips` resolution, IPv6 reachability, SSH, and OpenCode server access.

## macOS Package Verification and Source Fallback

For upstream macOS packages:

```bash
shasum -a 256 fips-0.4.0-rc1-macos-$(uname -m).pkg
pkgutil --check-signature fips-0.4.0-rc1-macos-$(uname -m).pkg
pkgutil --payload-files fips-0.4.0-rc1-macos-$(uname -m).pkg
rm -rf /tmp/fips-pkg-expanded-${USER} && pkgutil --expand fips-0.4.0-rc1-macos-$(uname -m).pkg /tmp/fips-pkg-expanded-${USER}
xar -tf fips-0.4.0-rc1-macos-$(uname -m).pkg
sudo installer -pkg fips-0.4.0-rc1-macos-$(uname -m).pkg -target /
```

Use source build only while upstream macOS packages are unavailable or fail integrity checks:

```bash
git clone https://github.com/jmcorgan/fips.git
cd fips
git checkout v0.4.0-rc1
./packaging/macos/build-pkg.sh

pkgutil --check-signature deploy/fips-0.4.0-rc1-macos-$(uname -m).pkg
pkgutil --payload-files deploy/fips-0.4.0-rc1-macos-$(uname -m).pkg
rm -rf /tmp/fips-source-pkg-expanded-${USER} && pkgutil --expand deploy/fips-0.4.0-rc1-macos-$(uname -m).pkg /tmp/fips-source-pkg-expanded-${USER}
sudo installer -pkg deploy/fips-0.4.0-rc1-macos-$(uname -m).pkg -target /
```

Prerequisites for source builds: Rust toolchain from https://rustup.rs and Xcode command line tools (`xcode-select --install`). Remove any previous user-scoped `/tmp/fips-*-pkg-expanded-${USER}` directory before expanding because `pkgutil --expand` fails when the destination already exists. Do not install if package integrity checks fail.

## Safe Local Posture

Initial macOS installs can start `/Library/LaunchDaemons/com.fips.daemon.plist`, create persistent keys under `/usr/local/etc/fips/`, register `/etc/resolver/fips`, and listen on all interfaces at `0.0.0.0:2121/udp` and `0.0.0.0:8443/tcp`. Observed `fipsctl acl show` can report `effective_mode: default_open` with enforcement inactive on a fresh single-node install.

If no trusted second node is available, validate the install, then stop and disable FIPS until ready to pair explicit peers:

```bash
fipsctl show status
fipsctl acl show
sudo launchctl bootout system /Library/LaunchDaemons/com.fips.daemon.plist
sudo launchctl disable system/com.fips.daemon
launchctl print system/com.fips.daemon
netstat -an -p tcp | rg '(:8443|\.8443)' || true
netstat -an -p udp | rg '(:2121|\.2121)' || true
```

Expected disabled `launchctl print` output includes `Bad request` and `Could not find service "com.fips.daemon" in domain for system`. Re-enable only for an intentional test window:

```bash
sudo launchctl enable system/com.fips.daemon
sudo launchctl bootstrap system /Library/LaunchDaemons/com.fips.daemon.plist
```

Do not expose SSH, OpenCode, dashboards, gateway, or exit-node modes until the peer ACL is explicit and tested.

## Secret Handling

WARNING: Never paste secret values into AI chat.

Use aidevops secret storage for private Nostr key recovery material and OpenCode access tokens:

```bash
aidevops secret set FIPS_NSEC
aidevops secret set OPENCODE_SERVER_TOKEN
```

Prefer fresh per-device identities over shared private keys. If a key is imported from `FIPS_NSEC`, write it only to the upstream-supported key file with owner-only permissions, then remove the environment value from shell history/session. Pass secrets as environment variables or secret-helper execution context, not command arguments.

## OpenCode Remote Compute Pattern

1. On the compute node, bind OpenCode or other local services to loopback or the FIPS interface only.
2. Open only the required port on `fips0`; keep public interfaces default-deny.
3. From the client node, connect using the peer `.fips` name or mapped IPv6 address.
4. Store service auth tokens with `aidevops secret set OPENCODE_SERVER_TOKEN`.
5. Verify with `nostr-vpn-helper.sh diagnostics` and an authenticated application-level request.

Other aidevops-adjacent candidates after SSH is proven: private Git remotes, MCP servers, local dashboards, homelab storage, GPU workers, staging apps, and CI/debug workers. Bind each service to loopback or the FIPS interface; do not publish public listeners as a shortcut.

## Helper Commands

```bash
.agents/scripts/nostr-vpn-helper.sh check
.agents/scripts/nostr-vpn-helper.sh status
.agents/scripts/nostr-vpn-helper.sh identity
.agents/scripts/nostr-vpn-helper.sh peers
.agents/scripts/nostr-vpn-helper.sh firewall-status
.agents/scripts/nostr-vpn-helper.sh diagnostics
.agents/scripts/nostr-vpn-helper.sh secrets-help
.agents/scripts/nostr-vpn-helper.sh macos-source
.agents/scripts/nostr-vpn-helper.sh safe-posture
.agents/scripts/nostr-vpn-helper.sh privacy-guide
.agents/scripts/nostr-vpn-helper.sh opencode-guide
```

The helper is intentionally read-only except for printing operator instructions; destructive or privileged changes should be confirmed and implemented in a later, tested phase.

## Security Checklist

- Confirm upstream release checksums before installing.
- Treat npubs as addresses, not proof that a device is trustworthy.
- Keep peer ACLs tight; default deny unknown peers.
- After install validation, disable the LaunchDaemon when no trusted peer is ready.
- Treat default-open ACL state as unsafe for exposing services.
- Enable `fips0` firewall rules before exposing SSH, OpenCode, dashboards, or LAN gateways.
- Avoid LAN gateway and exit-node mode until the trust boundary is explicit.
- Assume public Nostr relays can reveal metadata even when messages are encrypted.
- Use fresh per-purpose identities and private/self-hosted relays where practical.
- Use Tor, a no-logs VPN, or privacy-preserving transport only when IP hiding is part of the threat model; validate that the chosen FIPS transport actually uses it.
- Rotate the device identity after suspected compromise; remove stale peers from ACLs and known-hosts.

## Verification

Run:

```bash
.agents/scripts/nostr-vpn-helper.sh diagnostics
.agents/scripts/nostr-vpn-helper.sh macos-source
fipsctl show status
fipsctl show peers
ssh <user>@<peer-alias>.fips
```

If `fipsctl` output format changes, inspect upstream docs before updating aidevops parsing; do not guess around private key or ACL semantics.
