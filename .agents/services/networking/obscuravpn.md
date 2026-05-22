---
description: ObscuraVPN - two-party relay VPN with WireGuard-over-QUIC, Mullvad exits, and censorship resistance
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

# ObscuraVPN - Two-Party Relay VPN

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Privacy-by-design VPN/MPR: user → Obscura relay → Mullvad exit → internet.
- **Architecture**: WireGuard packets encrypted to the exit hop, carried over QUIC/datagrams to Obscura relay servers.
- **Privacy boundary**: Obscura can see connecting IP/account/payment metadata, not decrypted traffic; Mullvad exits see Obscura relay IP, not user identity.
- **Use for**: ObscuraVPN client work, MPR/two-party relay analysis, WireGuard-over-QUIC troubleshooting, app build guidance, privacy claims review.
- **Sources**: https://obscura.com/ · https://github.com/Sovereign-Engineering/obscuravpn-client · Privacy Guides MPR article.
- **Related**: `services/networking/netbird.md`, `services/networking/tailscale.md`, `tools/security/opsec.md`, `tools/mobile/app-dev.md`, `tools/mobile/app-dev-swift.md`, `legal.md`.

<!-- AI-CONTEXT-END -->

## Product Model

Obscura is closer to a commercial Multi-Party Relay than a traditional single-provider VPN. The key design claim is separation of **who the user is** from **what destinations they reach**:

```text
user device -> Obscura relay -> Mullvad WireGuard exit -> destination
```

Use precise wording:

- It is **not Tor**: two high-performance hops, not volunteer onion routing.
- It is **not normal multihop VPN**: the exit hop is operated by an independent provider.
- It is **not magic anonymity**: privacy depends on non-collusion and traffic-correlation resistance.
- It is **not full stealth in WireGuard compatibility mode**: generated WireGuard configs keep two-party privacy but lose QUIC-based obfuscation.

## Client Repository

Repository: https://github.com/Sovereign-Engineering/obscuravpn-client.

Observed repository shape:

- Rust core/library in `rustlib/`.
- Apple clients in `apple/`; macOS uses a sandboxed Network Extension.
- Android client in `android/`.
- UI in `obscura-ui/`.
- Platform support and build notes in `README.md`, `flake.nix`, and `justfile`.

Upstream contribution policy from the repository README: external contributions are currently not accepted; PRs may be closed unread until their paperwork process changes. For upstream work, produce issues/notes/repro cases or a fork patch only when explicitly requested.

## Build and Test Pointers

Prefer Nix/Just paths from the upstream README; do not invent commands.

| Area | Upstream pattern | Notes |
|------|------------------|-------|
| Lint | `nix develop --print-build-logs --command just lint` | Run before claiming code quality. |
| Format check | `nix flake check` | Use for formatting/flake validation. |
| Format fix | `nix develop --print-build-logs --command just format-fix` | Only when editing upstream code. |
| macOS/iOS | Xcode project via `nix develop --print-build-logs --command just xcode-open` | Codesigning and Network Extension entitlements may require Sovereign Engineering team access. |
| Android Nix build | `nix build '.#apks-foss'` | Signing/install steps need local keystore/device context. |

macOS app debugging uses Apple unified logging. Search predicates should target `process CONTAINS[c] "obscura"` or `subsystem CONTAINS[c] "obscura"`.

## Privacy and Security Review Checklist

When reviewing Obscura claims, verify against source or first-party docs before repeating:

1. **Tunnel boundary**: packets are encrypted to Mullvad WireGuard public keys before Obscura relay handling.
2. **Relay visibility**: Obscura relays cannot decrypt user traffic; Mullvad exits should only see relay source IPs.
3. **Transport**: QUIC/datagram transport is the censorship-resistance layer; WireGuard configs do not provide that layer.
4. **Account privacy**: randomized account numbers reduce account identifiers; payment methods still determine metadata exposure.
5. **Location claims**: separate relay locations from exit locations; do not conflate first-hop and exit-hop lists.
6. **Threat model**: document residual risks: relay/exit collusion, timing correlation, compromised client, payment/linkability, destination-side tracking.

## Common Tasks

### Compare with VPN, Tor, iCloud Private Relay, and OHTTP

- Traditional VPN: one provider can see user identity plus destination traffic metadata.
- Tor: stronger multi-hop anonymity, usually slower and more failure-prone for everyday traffic.
- iCloud Private Relay: commercial two-party relay limited to Apple ecosystems and constrained location choices.
- OHTTP: similar two-party privacy principle, but fit for transactional app/API traffic rather than whole-device proxying.
- Obscura: commercial whole-device VPN-style product with independent Mullvad exits and QUIC obfuscation in the app path.

### Troubleshoot client issues

1. Identify platform: macOS/iOS/Android/WireGuard compatibility mode.
2. Confirm app mode vs generated WireGuard config; this changes obfuscation expectations.
3. Inspect local logs with platform-native tooling; avoid collecting destination history or account/payment data.
4. Verify exit hop public key against Mullvad server information when diagnosing authenticity claims.
5. Reproduce with a non-sensitive destination and redact account IDs before sharing logs.

### Work on upstream code

1. Read upstream `README.md` for the exact platform flow.
2. Use a fork/worktree; do not open upstream PRs unless contribution policy changes or maintainer explicitly requests it.
3. Expect codesigning/provisioning blockers for production Apple builds.
4. Run the closest feasible Nix/Just validation and report any skipped checks with the missing dependency or credential.

## aidevops Integration

- Route ObscuraVPN, MPR, two-party relay, WireGuard-over-QUIC, Mullvad exit, QUIC obfuscation, and VPN privacy review tasks here first.
- For app implementation, combine with `tools/mobile/app-dev.md`, `tools/mobile/app-dev-swift.md`, or Android guidance after this agent sets protocol/threat-model context.
- For operational access to private infrastructure, use `services/networking/netbird.md` or `services/networking/tailscale.md`; Obscura is for internet egress privacy/censorship resistance, not private mesh access.
- For OPSEC/legal/privacy-policy work, combine with `tools/security/opsec.md` and `legal.md`.

## Related Agents

| Resource | Path | Purpose |
|----------|------|---------|
| NetBird | `services/networking/netbird.md` | Self-hosted WireGuard mesh VPN and worker access. |
| Tailscale | `services/networking/tailscale.md` | Managed mesh VPN, Serve/Funnel, and secure private access. |
| OPSEC | `tools/security/opsec.md` | Threat modelling and operational privacy discipline. |
| Mobile app development | `tools/mobile/app-dev.md` | App planning/build/release workflows. |
| Mobile app development (Swift) | `tools/mobile/app-dev-swift.md` | Swift/iOS-specific app development guidance. |
| Legal | `legal.md` | Legal compliance, privacy policy, and GDPR guidance. |

Tier guidance: the agents listed above are shared framework agents maintained in `.agents/`. Use `custom/` for permanent private variants and `draft/` for R&D or unreviewed patterns; see `tools/build-agent/build-agent.md` for lifecycle rules and `reference/customization.md` for persistence/update behaviour.
