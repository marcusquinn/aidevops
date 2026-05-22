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
- **Status**: Experimental; upstream says protocol/API are not stable and security audit is pending.
- **Secrets**: Use `aidevops secret set FIPS_NSEC` only for import/recovery; never paste Nostr private keys into chat or commit key files.

**Key concepts**: Nostr keypair identity · npub node address · FIPS mesh · IPv6 `fd00::/8` TUN · `.fips` DNS · Nostr-mediated discovery · peer ACL · optional `fips0` firewall · LAN gateway · WireGuard exit sidecar.

<!-- AI-CONTEXT-END -->

## Decision Guidance

Use **Nostr VPN/FIPS** when self-sovereign identity and no central control plane matter more than mature administration. Use **NetBird** for teams, SSO, API-managed ACLs, policy UX, and production support. Use **Tailscale** for fastest onboarding where SaaS control-plane dependency is acceptable.

Do not present FIPS as the default aidevops networking layer until upstream protocol stability and security audit status improve.

## aidevops Use Cases

- Secure SSH and OpenCode server access between personal devices across networks.
- Reach workstation/GPU/storage resources from laptop without exposing public ports.
- Build a self-hosted mesh spanning homelab, VPS, mobile, and travel devices.
- Run aidevops helpers on one node while using compute or services on another.
- Test resilient routing over UDP, TCP, Ethernet, Tor, or Bluetooth transports.

## Setup Pattern

1. Install FIPS from an upstream release or package; verify checksums first.
2. On macOS, also verify package integrity with `pkgutil --check-signature`, `pkgutil --payload-files`, or `pkgutil --expand`; do not install packages that fail these checks even when the release checksum matches.
3. Generate a persistent identity on each device, or import one from `aidevops secret set FIPS_NSEC` during recovery only.
4. Record device **npubs**, labels, and intended roles in local config; never store private keys in git.
5. Configure peer ACLs before joining wider meshes.
6. Enable the optional `fips0` firewall baseline before exposing services.
7. Test `.fips` resolution, IPv6 reachability, SSH, and OpenCode server access.

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

## Helper Commands

```bash
.agents/scripts/nostr-vpn-helper.sh check
.agents/scripts/nostr-vpn-helper.sh status
.agents/scripts/nostr-vpn-helper.sh identity
.agents/scripts/nostr-vpn-helper.sh peers
.agents/scripts/nostr-vpn-helper.sh firewall-status
.agents/scripts/nostr-vpn-helper.sh diagnostics
.agents/scripts/nostr-vpn-helper.sh secrets-help
.agents/scripts/nostr-vpn-helper.sh opencode-guide
```

The helper is intentionally read-only except for printing operator instructions; destructive or privileged changes should be confirmed and implemented in a later, tested phase.

## Security Checklist

- Confirm upstream release checksums before installing.
- Treat npubs as addresses, not proof that a device is trustworthy.
- Keep peer ACLs tight; default deny unknown peers.
- Enable `fips0` firewall rules before exposing SSH, OpenCode, dashboards, or LAN gateways.
- Avoid LAN gateway and exit-node mode until the trust boundary is explicit.
- Assume public Nostr relays can reveal metadata even when messages are encrypted.
- Rotate the device identity after suspected compromise; remove stale peers from ACLs and known-hosts.

## Verification

Run:

```bash
.agents/scripts/nostr-vpn-helper.sh diagnostics
fipsctl show status
fipsctl show peers
ssh <user>@<peer-alias>.fips
```

If `fipsctl` output format changes, inspect upstream docs before updating aidevops parsing; do not guess around private key or ACL semantics.
