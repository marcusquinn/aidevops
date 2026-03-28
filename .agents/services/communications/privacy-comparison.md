---
description: Privacy/security comparison matrix for all 15 chat platform integrations — select by threat model. Max privacy → SimpleX. E2E mainstream → Signal. Corporate compliance → Nextcloud Talk. Censorship resistance → Nostr/Urbit. Related: `tools/security/opsec.md`, `services/communications/`.
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Chat Platform Privacy Comparison Matrix

## Encryption

| Platform | E2E Default | Bot E2E | Protocol |
|----------|-------------|---------|----------|
| **SimpleX** | Yes | Yes | X3DH + Curve448, NaCl |
| **Signal** | Yes | Yes | Double Ratchet + X3DH, Curve25519, AES-256 |
| **XMTP** | Yes | Yes | MLS (RFC 9420) + post-quantum hybrid |
| **Bitchat** | Yes | N/A | Noise_XX_25519_ChaChaPoly_SHA256 |
| **Nostr** | DMs only | DMs only | NIP-04: secp256k1 ECDH + AES-256-CBC |
| **Matrix** | Per-room opt-in | If room E2E | Megolm (group), Olm (1:1) |
| **iMessage** | Yes | Yes (BlueBubbles) | ECDSA P-256 / RSA-2048 + AES |
| **WhatsApp** | Yes | Yes (Baileys) | Signal Protocol |
| **Telegram** | No (Secret Chats only) | No | MTProto 2.0 (server-client) |
| **Nextcloud Talk** | No (E2E calls only) | No | TLS 1.2+, AES-256-CTR at rest |
| **Urbit** | Yes | Yes | Curve25519 + AES (Ames) |
| **Slack** | No | No | TLS + AES-256 at rest |
| **Discord** | No | No | TLS + encryption at rest |
| **Google Chat** | No | No | TLS + AES-256 at rest |
| **MS Teams** | No | No | TLS + BitLocker + per-file |

### Metadata Collection

| Platform | Metadata Exposure | Social Graph | IP Logged |
|----------|-------------------|-------------|-----------|
| **SimpleX** | None | No (no user IDs) | Minimal (relay only) |
| **Bitchat** | None | No (BLE mesh) | No (no internet) |
| **Urbit** | Minimal | P2P only | NAT traversal nodes only |
| **Signal** | Minimal | Sealed sender | Minimal |
| **XMTP** | Minimal | Node operators see wallet addrs | Node operators |
| **Nostr** | Moderate | Relay sees pubkeys | Relay sees IPs |
| **Matrix** | Moderate | Server sees room membership | Server sees IPs |
| **iMessage** | Moderate | Apple sees sender/recipient | Apple sees IPs |
| **Telegram** | Extensive | Full social graph | All IPs |
| **WhatsApp** | Extensive | Full (Meta harvests) | All IPs |
| **Nextcloud Talk** | Self-controlled | Only your server | Only your server |
| **Slack/Discord/Google Chat/MS Teams** | Extensive | Full (platform operator) | Full |

### Identity Requirements

| Platform | Phone | Email | Anonymous |
|----------|-------|-------|-----------|
| **SimpleX** | No | No | Yes (fully) |
| **Bitchat** | No | No | Yes |
| **Nostr** | No | No | Yes (pseudonymous) |
| **Urbit** | No | No | Comets are free/anonymous |
| **XMTP** | No | No | Pseudonymous (wallet) |
| **Signal** | Yes | No | No |
| **Telegram** | Yes | No | No |
| **WhatsApp** | Yes | No | No |
| **iMessage** | Yes (or Apple ID) | Optional | No |
| **Matrix** | No | Optional | Possible (self-hosted) |
| **Nextcloud Talk** | No | Optional | Possible (self-hosted) |
| **Slack** | No | Yes | No |
| **Discord** | No | Yes | Pseudonymous |
| **Google Chat** | No | Yes (Workspace) | No |
| **MS Teams** | No | Yes (M365) | No |

### AI Training and Data Processing

| Platform | AI Training | Opt-Out | Data Monetization |
|----------|-------------|---------|-------------------|
| **SimpleX/Signal/Bitchat/Urbit/XMTP** | None | N/A | None |
| **Nostr** | Relay-dependent | N/A | Relay-dependent |
| **Matrix** | Server-dependent | Server admin | None |
| **Nextcloud Talk** | None (self-hosted) | Full control | None |
| **iMessage** | None (Apple policy) | Yes | None |
| **Telegram** | Unclear | Limited | Ads (channels) |
| **WhatsApp** | Metadata (Meta) | Limited | Ad targeting |
| **Slack** | Default opt-in | Admin opt-out | Enterprise analytics |
| **Discord** | Policy allows | User toggle (limited) | Nitro/boosts |
| **Google Chat** | Default enabled | Admin opt-out | Ad ecosystem |
| **MS Teams** | Default enabled | Admin opt-out | M365 ecosystem |

### Open Source and Auditability

| Platform | Client | Server | Audit |
|----------|--------|--------|-------|
| **SimpleX** | AGPL-3.0 | AGPL-3.0 | Trail of Bits |
| **Signal** | AGPL-3.0 | AGPL-3.0 | Multiple firms |
| **Matrix** | Apache-2.0 | Apache-2.0 | Yes |
| **Nostr/Urbit** | MIT | MIT | Community |
| **XMTP** | MIT | Open | NCC Group |
| **Bitchat** | Unlicense | Unlicense | Community |
| **Nextcloud Talk** | AGPL-3.0 | AGPL-3.0 | HackerOne |
| **Telegram** | GPLv2 (client) | Proprietary | Client only |
| **iMessage/WhatsApp** | Proprietary | Proprietary | No |
| **Slack/Discord/Google Chat/MS Teams** | SDK only | Proprietary | No |

### Self-Hosting and Data Sovereignty

| Platform | Self-Hostable | Federation |
|----------|--------------|------------|
| **SimpleX** | Yes (SMP + XFTP) | Decentralized |
| **Matrix** | Yes (Synapse/Dendrite) | Federated |
| **Nextcloud Talk** | Yes (full stack) | No |
| **Urbit** | Yes (personal server) | P2P |
| **Nostr** | Yes (relay) | Relay-based |
| **Bitchat** | N/A (P2P mesh) | BLE mesh |
| **XMTP** | Partial (node operator) | Decentralized |
| **Signal** | Partial (server open) | Centralized (US) |
| **Telegram/iMessage/WhatsApp/Slack/Discord** | No | Centralized (US) |
| **Google Chat/MS Teams** | No | Centralized (US, EU option) |

### Push Notification Privacy

| Platform | Content in Push | Metadata Exposed |
|----------|----------------|------------------|
| **SimpleX** | No | Minimal (notification ID only) |
| **Signal** | No | Minimal ("new message" only) |
| **Bitchat/Urbit/Nostr** | N/A | None |
| **XMTP** | Minimal | Minimal |
| **Nextcloud Talk** | No (wake signal) | Eliminable (self-hosted proxy) |
| **Matrix** | Configurable | Server-dependent |
| **iMessage** | No | Apple sees device token + timing |
| **Telegram** | Encrypted content | Timing to Google/Apple |
| **WhatsApp** | No | Timing to Google/Apple |
| **Slack/Discord/MS Teams** | Preview (default) | Full metadata to Google/Apple |
| **Google Chat** | Unencrypted (Android) | Full (Google sees everything) |

### Runner Dispatch Suitability

| Platform | Bot API | Feasibility | Key Limitation |
|----------|---------|-------------|----------------|
| **Matrix** | Mature (SDK) | Excellent | Requires homeserver |
| **Telegram** | Very mature (Bot API) | Excellent | No E2E for bots |
| **Slack** | Mature (Bolt SDK) | Excellent | No E2E, AI training risk |
| **Discord** | Mature (discord.js) | Excellent | No E2E, AI training risk |
| **SimpleX** | Growing (WebSocket JSON) | Good | Group scalability experimental |
| **Signal** | Unofficial (signal-cli) | Good | No official API, phone required |
| **MS Teams** | Mature (Bot Framework) | Good | Azure dependency, no E2E |
| **XMTP** | First-class (Agent SDK) | Good | Small user base |
| **Google Chat** | Moderate (webhook) | Moderate | Public URL required, Gemini risk |
| **Nostr** | Growing (nostr-tools) | Moderate | No rich UI, relay reliability |
| **Nextcloud Talk** | Basic (webhook) | Moderate | Self-hosted requirement |
| **WhatsApp** | Unofficial (Baileys) | Risky | Account ban risk, Meta metadata |
| **iMessage** | Unofficial (BlueBubbles) | Limited | macOS-only, no official API |
| **Urbit** | Minimal (HTTP API) | Experimental | Niche, steep learning curve |
| **Bitchat** | None | Not feasible | BLE-only, no bot API |

## Threat Model Recommendations

### T4: Nation-State (Maximum Privacy)

- **Primary**: SimpleX — no user identifiers, stateless servers, E2E everything, AGPL-3.0, audited.
- **Secondary**: Signal — E2E default, sealed sender, minimal metadata. Phone number is the main weakness.
- **Supplementary**: Urbit — maximum sovereignty, niche ecosystem.
- **Avoid**: All corporate platforms, Telegram (no default E2E), WhatsApp (Meta metadata).
- **Network layer**: Mullvad VPN + Tor. See `tools/security/opsec.md`.

### T2-T3: Strong Privacy + Mainstream Reach

- **Primary**: Signal — 40M+ users, E2E default, non-profit, no AI training.
- **Bridge**: Matterbridge Signal→Matrix for team features. Privacy users stay on Signal.
- **Acceptable**: Matrix (self-hosted, E2E rooms), iMessage (strong E2E, iCloud backup risk).
- **Caution**: WhatsApp — content E2E but Meta harvests metadata. Use only when recipient won't switch.

### Corporate Compliance (Regulated Industries)

- **Best**: Nextcloud Talk (self-hosted) — GDPR/HIPAA configurable, full audit logs, no third-party access.
- **Acceptable**: Slack, MS Teams, Google Chat — compliance features (eDiscovery, DLP, retention) at the cost of platform operator access.
- **AI risk**: All three have AI features processing message content. Admins must explicitly opt out. Google Chat's Gemini is most aggressive.

### Censorship Resistance

- **Primary**: Nostr — decentralized relays, no single censorship point, keypair identity.
- **Maximum**: Urbit — fully P2P, own server and identity. Requires always-on infra.
- **Offline**: Bitchat — BLE mesh, no internet. For protests, disasters, shutdowns.
- **Avoid**: All centralized platforms.

### Low Threat Model (Convenience)

- **Recommended**: Telegram (large user base, mature bot API) or WhatsApp (largest global base, E2E content).
- **Teams**: Slack or Discord — mature bot ecosystems, zero privacy from platform operator.

## Platform Privacy Ranking

| Rank | Platform | Grade | Strength | Weakness |
|------|----------|-------|----------|----------|
| 1 | **SimpleX** | A+ | No identifiers, stateless | Smaller user base |
| 2 | **Bitchat** | A+ | No internet, no servers | BLE range, no bot API |
| 3 | **Urbit** | A | Full sovereignty, P2P | Niche, steep learning |
| 4 | **Signal** | A | E2E default, audited | Phone required |
| 5 | **XMTP** | A- | MLS + post-quantum | Small ecosystem |
| 6 | **Nostr** | B+ | Censorship-resistant | DM metadata at relays |
| 7 | **Matrix** | B+ | Federated, self-hostable | E2E not default |
| 8 | **Nextcloud Talk** | B+ | Self-hosted, full control | No E2E for messages |
| 9 | **iMessage** | B | E2E default | Closed source, iCloud risk |
| 10 | **Telegram** | C+ | Client open-source | No default E2E, full metadata |
| 11 | **WhatsApp** | C | Signal Protocol E2E | Meta metadata harvesting |
| 12 | **Discord** | D | Community ecosystem | No E2E, AI training |
| 13 | **Slack** | D | Compliance features | No E2E, AI default-on |
| 14 | **MS Teams** | D | Enterprise compliance | No E2E, Copilot |
| 15 | **Google Chat** | D- | Workspace integration | No E2E, Gemini most aggressive |

## Matterbridge Bridging

**Privacy warning**: Bridging E2E platforms (Signal, SimpleX) to non-E2E (Slack, Discord) stores messages unencrypted on the non-E2E platform. Inform users of this degradation.

| Platform | Native Support | Notes |
|----------|---------------|-------|
| **Telegram** | Yes | Most mature gateway |
| **Signal** | Yes (signal-cli) | Requires signal-cli daemon |
| **Slack** | Yes | Bot token |
| **Discord** | Yes | Bot token, privileged intents |
| **Matrix** | Yes | Full support |
| **WhatsApp** | Yes (whatsmeow) | Same ban risk as Baileys |
| **MS Teams** | Yes | Bot Framework |
| **Nextcloud Talk** | Yes | Native |
| **SimpleX** | Custom adapter | Requires bridge bot process |
| **Google Chat/iMessage/Nostr/XMTP/Urbit** | No | Custom gateway needed |
| **Bitchat** | No | Not feasible (BLE only) |

## Related

`tools/security/opsec.md` · `services/communications/` (per-platform docs) · `services/communications/matterbridge.md`
