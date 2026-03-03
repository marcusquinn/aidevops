---
description: Cross-platform privacy comparison matrix — encryption, metadata, self-hosting, open source, data sovereignty, AI training, and runner dispatch suitability for all supported chat platform integrations
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

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Side-by-side privacy and security comparison of all 15 chat platform integrations
- **Scope**: E2E encryption, metadata collection, self-hosting, open source, data sovereignty, AI training, runner dispatch suitability
- **Use**: Select the right platform for your threat model and operational requirements
- **Related**: `tools/security/opsec.md` (threat modeling), individual platform docs in `services/communications/`

**Decision shortcut**: If you need maximum privacy, use SimpleX. If you need mainstream reach with strong encryption, use Signal. If you need corporate compliance, use Nextcloud Talk (self-hosted) or accept the trade-offs of Slack/Teams/Google Chat. If you need censorship resistance, use Nostr or Urbit.

<!-- AI-CONTEXT-END -->

## Comparison Matrix

### Encryption

| Platform | Encryption Type | E2E Default | Bot Messages E2E | Protocol |
|----------|----------------|-------------|------------------|----------|
| **SimpleX** | E2E (Double Ratchet) | Yes | Yes | X3DH + Curve448, NaCl crypto_box |
| **Signal** | E2E (Signal Protocol) | Yes | Yes (via signal-cli) | Double Ratchet + X3DH, Curve25519, AES-256 |
| **XMTP** | E2E (MLS) | Yes | Yes | MLS (RFC 9420) + post-quantum hybrid |
| **Bitchat** | E2E (Noise Protocol) | Yes | N/A (no bot API) | Noise_XX_25519_ChaChaPoly_SHA256 |
| **Nostr** | E2E (DMs only) | DMs only | DMs only | NIP-04: secp256k1 ECDH + AES-256-CBC |
| **Matrix** | E2E (optional) | Per-room opt-in | If room has E2E on | Megolm (group), Olm (1:1) |
| **iMessage** | E2E | Yes | Yes (via BlueBubbles) | ECDSA P-256 / RSA-2048 + AES |
| **WhatsApp** | E2E (Signal Protocol) | Yes | Yes (via Baileys) | Same as Signal |
| **Telegram** | Transport only (default) | No (Secret Chats only) | No | MTProto 2.0 (server-client) |
| **Nextcloud Talk** | TLS + at-rest | No (E2E for 1:1 calls) | No | TLS 1.2+, AES-256-CTR at rest |
| **Urbit** | E2E (Ames) | Yes | Yes | Curve25519 + AES (Ames protocol) |
| **Slack** | Transport only | No | No | TLS 1.2+ in transit, AES-256 at rest |
| **Discord** | Transport only | No | No | TLS in transit, encryption at rest |
| **Google Chat** | Transport only | No | No | TLS 1.2+ in transit, AES-256 at rest |
| **MS Teams** | Transport only | No | No | TLS 1.2+ in transit, BitLocker + per-file encryption |

### Metadata Collection

| Platform | Metadata Exposure | Social Graph Visible | Timestamps Visible | IP Logged |
|----------|-------------------|---------------------|-------------------|-----------|
| **SimpleX** | None | No (no user IDs) | No (stateless servers) | Minimal (relay only) |
| **Bitchat** | None | No (BLE mesh) | No | No (no internet) |
| **Urbit** | Minimal | P2P only (no central) | P2P only | NAT traversal nodes only |
| **Signal** | Minimal | Sealed sender hides sender | Registration + last connect only | Minimal |
| **XMTP** | Minimal | Node operators see wallet addresses | Node operators see timing | Node operators |
| **Nostr** | Moderate (DMs) | Relay sees sender/recipient pubkeys | Relay sees timestamps | Relay sees IPs |
| **Matrix** | Moderate | Server sees room membership | Server sees timestamps | Server sees IPs |
| **iMessage** | Moderate | Apple sees sender/recipient | Apple sees timestamps (30d) | Apple sees IPs |
| **Telegram** | Extensive | Full social graph | All timestamps | All IPs |
| **WhatsApp** | Extensive | Full social graph (Meta harvests) | All timestamps | All IPs |
| **Nextcloud Talk** | Self-controlled | Only your server | Only your server | Only your server |
| **Slack** | Extensive | Full (Salesforce) | Full history | Full |
| **Discord** | Extensive | Full (Discord Inc.) | Full history | Full |
| **Google Chat** | Extensive | Full (Google) | Full history | Full |
| **MS Teams** | Extensive | Full (Microsoft) | Full history | Full |

### Identity Requirements

| Platform | Phone Required | Email Required | Other Identity | Anonymous Use |
|----------|---------------|---------------|----------------|---------------|
| **SimpleX** | No | No | None | Yes (fully anonymous) |
| **Bitchat** | No | No | Pubkey fingerprint (auto-generated) | Yes |
| **Nostr** | No | No | Keypair (nsec/npub) | Yes (pseudonymous) |
| **Urbit** | No | No | Urbit ID (NFT, purchased) | Comets are free/anonymous |
| **XMTP** | No | No | Wallet/DID/passkey | Pseudonymous (wallet address) |
| **Signal** | Yes | No | Phone number (E.164) | No |
| **Telegram** | Yes | No | Phone + optional username | No |
| **WhatsApp** | Yes | No | Phone number | No |
| **iMessage** | Yes (or Apple ID) | Optional | Apple ID | No |
| **Matrix** | No | Optional | `@user:server` | Possible (self-hosted) |
| **Nextcloud Talk** | No | Optional | Nextcloud user account | Possible (self-hosted) |
| **Slack** | No | Yes (workspace) | Workspace email | No |
| **Discord** | No | Yes | Email + username | Pseudonymous |
| **Google Chat** | No | Yes (Workspace) | Google Workspace account | No |
| **MS Teams** | No | Yes (M365) | Azure AD account | No |

### AI Training and Data Processing

| Platform | AI Training Policy | AI Features in Chat | Opt-Out Available | Data Monetization |
|----------|-------------------|--------------------|--------------------|-------------------|
| **SimpleX** | None | None | N/A | None |
| **Signal** | None (non-profit) | None | N/A | None |
| **Bitchat** | None | None | N/A | None |
| **Urbit** | None (self-hosted) | None | N/A | None |
| **Nostr** | None (protocol-level) | None | N/A | None |
| **XMTP** | None | None | N/A | None |
| **Matrix** | None (Foundation) | None | N/A | None |
| **Nextcloud Talk** | None (self-hosted) | Optional local AI only | Full control | None |
| **iMessage** | None (Apple policy) | Apple Intelligence (on-device) | Yes | None |
| **Telegram** | Unclear | Translation, AI chatbot (Premium) | Limited | Ads (channels) |
| **WhatsApp** | Metadata used (Meta) | Meta AI chatbot | Limited | Ad targeting via metadata |
| **Slack** | Default opt-in | Slack AI (summaries, search) | Admin opt-out required | Enterprise analytics |
| **Discord** | Policy allows | Clyde (discontinued), summaries | User toggle (limited) | Nitro, boosts |
| **Google Chat** | Default enabled | Gemini (most aggressive) | Admin opt-out required | Ad ecosystem |
| **MS Teams** | Default enabled | Copilot (extensive) | Admin opt-out required | M365 ecosystem |

### Open Source and Auditability

| Platform | Client Source | Server Source | Protocol Source | Independent Audit |
|----------|-------------|--------------|----------------|-------------------|
| **SimpleX** | AGPL-3.0 | AGPL-3.0 | AGPL-3.0 | Yes (Trail of Bits) |
| **Signal** | AGPL-3.0 | AGPL-3.0 | Open (Signal Protocol) | Yes (multiple firms) |
| **Matrix** | Apache-2.0 | Apache-2.0 (Synapse) | Open | Yes |
| **Nostr** | MIT (clients) | MIT/various (relays) | Open (NIPs) | Community-reviewed |
| **Urbit** | MIT | MIT | MIT | Community-reviewed |
| **XMTP** | MIT | Open protocol | Open (MLS) | Yes (NCC Group) |
| **Bitchat** | Unlicense | Unlicense | Open (Noise) | Community-reviewed |
| **Nextcloud Talk** | AGPL-3.0 | AGPL-3.0 | Open | Yes (HackerOne bounty) |
| **Telegram** | GPLv2 (client) | Proprietary | Proprietary (MTProto) | Client only |
| **iMessage** | Proprietary | Proprietary | Proprietary | No (Apple self-reports) |
| **WhatsApp** | Proprietary | Proprietary | Signal Protocol (open) | Protocol only |
| **Slack** | MIT (SDK only) | Proprietary | Proprietary | No |
| **Discord** | Apache-2.0 (SDK) | Proprietary | Proprietary | No |
| **Google Chat** | Apache-2.0 (SDK) | Proprietary | Proprietary | No |
| **MS Teams** | MIT (SDK only) | Proprietary | Proprietary | No |

### Self-Hosting and Data Sovereignty

| Platform | Self-Hostable | Data Location | Jurisdiction | Federation |
|----------|-------------|---------------|-------------|------------|
| **SimpleX** | Yes (SMP + XFTP) | Your servers | Your choice | Decentralized |
| **Matrix** | Yes (Synapse/Dendrite) | Your servers | Your choice | Federated |
| **Nextcloud Talk** | Yes (full stack) | Your servers | Your choice | No (single instance) |
| **Urbit** | Yes (personal server) | Your ship | Your choice | P2P (no federation needed) |
| **Nostr** | Yes (relay) | Your relay + others | Distributed | Relay-based |
| **Bitchat** | N/A (P2P mesh) | Device-only | Physical location | BLE mesh |
| **XMTP** | Partial (node operator) | Node operators | Distributed | Decentralized nodes |
| **Signal** | Partial (server open) | Signal Foundation (US) | USA | Centralized |
| **Telegram** | No (client only) | Telegram servers | Dubai, UAE | Centralized |
| **iMessage** | No | Apple servers | USA | Centralized |
| **WhatsApp** | No | Meta servers | USA | Centralized |
| **Slack** | No | Salesforce/AWS | USA | Centralized |
| **Discord** | No | Discord/GCP | USA | Centralized |
| **Google Chat** | No | Google Cloud | USA (EU option) | Centralized |
| **MS Teams** | No | Microsoft Azure | USA (EU option) | Centralized |

### Push Notification Privacy

| Platform | Push Provider | Content in Push | Metadata Exposed |
|----------|-------------|----------------|------------------|
| **SimpleX** | Optional (FCM/APNs) | No content | Minimal (notification ID only) |
| **Signal** | FCM/APNs | No content | Minimal ("new message" signal only) |
| **Bitchat** | None (no internet) | N/A | None |
| **Urbit** | None (always-on server) | N/A | None |
| **Nostr** | None (client polling) | N/A | None |
| **XMTP** | Optional | Minimal | Minimal |
| **Nextcloud Talk** | Self-hosted proxy option | No content (wake signal) | Eliminable with self-hosted proxy |
| **Matrix** | FCM/APNs (configurable) | Configurable | Server-dependent |
| **iMessage** | APNs (mandatory) | No content | Apple sees device token + timing |
| **Telegram** | FCM/APNs | Encrypted content | Timing visible to Google/Apple |
| **WhatsApp** | FCM/APNs | No content | Timing visible to Google/Apple |
| **Slack** | FCM/APNs | Message preview (default) | Full metadata to Google/Apple |
| **Discord** | FCM/APNs | Message preview (default) | Full metadata to Google/Apple |
| **Google Chat** | FCM (Google's own) | Unencrypted on Android | Full (Google sees everything) |
| **MS Teams** | WNS/FCM/APNs | Message preview (default) | Full metadata |

### Runner Dispatch Suitability

| Platform | Bot API Maturity | Dispatch Feasibility | Key Limitation | Recommended For |
|----------|-----------------|---------------------|----------------|-----------------|
| **SimpleX** | Growing (WebSocket JSON) | Good | Group scalability experimental | Private agent-to-agent, high-security dispatch |
| **Signal** | Unofficial (signal-cli) | Good | No official bot API, phone required | Privacy-conscious users, E2E dispatch |
| **Matrix** | Mature (SDK) | Excellent | Requires homeserver | Team collaboration, bridged dispatch |
| **Telegram** | Very mature (Bot API) | Excellent | No E2E for bots | Large communities, public bots |
| **Slack** | Mature (Bolt SDK) | Excellent | No E2E, AI training risk | Corporate teams (accepted trade-off) |
| **Discord** | Mature (discord.js) | Excellent | No E2E, AI training risk | Community engagement |
| **MS Teams** | Mature (Bot Framework) | Good | Azure dependency, no E2E | Enterprise M365 environments |
| **Google Chat** | Moderate (webhook) | Moderate | Public URL required, Gemini risk | Google Workspace teams |
| **WhatsApp** | Unofficial (Baileys) | Risky | Account ban risk, Meta metadata | Reaching existing WhatsApp users |
| **iMessage** | Unofficial (BlueBubbles) | Limited | macOS-only, no official API | Apple ecosystem notifications |
| **Nostr** | Growing (nostr-tools) | Moderate | No rich UI, relay reliability | Censorship-resistant dispatch |
| **XMTP** | First-class (Agent SDK) | Good | Small user base | Web3/wallet-native dispatch |
| **Nextcloud Talk** | Basic (webhook) | Moderate | Self-hosted requirement | Self-hosted corporate dispatch |
| **Urbit** | Minimal (HTTP API) | Experimental | Niche ecosystem, steep learning | Maximum sovereignty dispatch |
| **Bitchat** | None | Not feasible | BLE-only, no bot API | Offline/emergency comms only |

## Threat Model Recommendations

### Maximum Privacy (Threat Tier T4: Nation-State)

**Primary**: SimpleX -- no user identifiers, stateless servers, E2E everything, AGPL-3.0, audited.

**Secondary**: Signal -- E2E by default, sealed sender, minimal metadata, proven in court (subpoena responses show near-zero data). Phone number requirement is the main weakness.

**Supplementary**: Urbit -- maximum sovereignty (own your server, identity, data), but niche ecosystem limits practical use.

**Avoid**: All corporate platforms (Slack, Teams, Discord, Google Chat), Telegram (no default E2E, proprietary server), WhatsApp (Meta metadata harvesting).

**Network layer**: Combine with Mullvad VPN + Tor for network-level privacy. See `tools/security/opsec.md`.

### Strong Privacy with Mainstream Reach (Threat Tier T2-T3)

**Primary**: Signal -- 40M+ users, E2E by default, non-profit, no AI training. Best balance of privacy and reach.

**Bridge strategy**: Use Matterbridge to bridge Signal to Matrix for team collaboration. Users who need maximum privacy stay on Signal; team features available via Matrix.

**Acceptable**: Matrix (self-hosted, E2E rooms enabled), iMessage (strong E2E but Apple ecosystem lock-in, iCloud backup risk).

**Caution**: WhatsApp -- content is E2E encrypted (Signal Protocol) but Meta harvests extensive metadata for ad targeting. Use only when the recipient is already on WhatsApp and won't switch.

### Corporate Compliance (Regulated Industries)

**Best option**: Nextcloud Talk (self-hosted) -- you control everything, GDPR/HIPAA configurable, full audit logs, no third-party data access. Strongest privacy of any corporate-style platform.

**Acceptable**: Slack, MS Teams, Google Chat -- all provide compliance features (eDiscovery, DLP, audit logs, retention policies) that regulated industries require. The trade-off is that the platform operator has full access to all content.

**Key decision**: Do you need the compliance features (legal holds, eDiscovery, content search) that corporate platforms provide? If yes, accept the privacy trade-off. If no, use Nextcloud Talk.

**AI training risk**: All three corporate platforms (Slack, Teams, Google Chat) have AI features that process message content. Workspace admins must explicitly opt out. Google Chat's Gemini integration is the most aggressive (enabled by default in most configurations).

### Censorship Resistance

**Primary**: Nostr -- decentralized relay architecture, no single point of censorship, keypair identity (no PII), anyone can run a relay.

**Maximum**: Urbit -- fully decentralized P2P, no relays needed, own your server and identity. But requires always-on infrastructure and has a steep learning curve.

**Offline**: Bitchat -- BLE mesh, no internet required. Useful for protests, natural disasters, or internet shutdowns. Limited to physical proximity.

**Avoid**: All centralized platforms -- a single operator can deplatform you.

### Mainstream Convenience (Low Threat Model)

**Recommended**: Telegram (large user base, feature-rich bot API, good enough for non-sensitive communication) or WhatsApp (largest global user base, E2E content encryption).

**For teams**: Slack or Discord -- mature bot ecosystems, rich interactive features, but zero privacy from the platform operator.

**Key understanding**: "Convenient" and "private" are inversely correlated for messaging platforms. The platforms with the largest user bases and richest features are the ones with the most data collection.

## Platform Privacy Ranking

Ranked by overall privacy posture, considering encryption, metadata, open source, self-hosting, and AI training:

| Rank | Platform | Privacy Grade | Key Strength | Key Weakness |
|------|----------|-------------|-------------|-------------|
| 1 | **SimpleX** | A+ | No identifiers, stateless servers | Smaller user base |
| 2 | **Bitchat** | A+ | No internet, no servers | BLE range only, no bot API |
| 3 | **Urbit** | A | Full sovereignty, P2P encrypted | Niche, steep learning curve |
| 4 | **Signal** | A | E2E default, audited, non-profit | Phone number required |
| 5 | **XMTP** | A- | MLS + post-quantum, agent-first | Small ecosystem |
| 6 | **Nostr** | B+ | Censorship-resistant, no PII | DM metadata visible to relays |
| 7 | **Matrix** | B+ | Federated, self-hostable, E2E option | E2E not default, server sees metadata |
| 8 | **Nextcloud Talk** | B+ | Self-hosted, full control | No E2E for messages (calls only) |
| 9 | **iMessage** | B | E2E default, Apple privacy stance | Closed source, iCloud backup risk, SMS fallback |
| 10 | **Telegram** | C+ | Client open-source, large user base | No default E2E, proprietary server, full metadata |
| 11 | **WhatsApp** | C | Signal Protocol E2E for content | Meta metadata harvesting, closed source |
| 12 | **Discord** | D | Large community ecosystem | No E2E, AI training, content scanning |
| 13 | **Slack** | D | Corporate compliance features | No E2E, AI training default-on |
| 14 | **MS Teams** | D | Enterprise compliance, Copilot | No E2E, Copilot processes all content |
| 15 | **Google Chat** | D- | Google Workspace integration | No E2E, Gemini most aggressive AI integration |

## Matterbridge Bridging Support

Matterbridge enables cross-platform message bridging. Privacy degrades to the weakest platform in any bridge.

| Platform | Matterbridge Native | Bridge Notes |
|----------|-------------------|-------------|
| **Telegram** | Yes | Full support, most mature gateway |
| **Signal** | Yes (via signal-cli) | Requires signal-cli daemon |
| **Slack** | Yes | Bot token authentication |
| **Discord** | Yes | Bot token, privileged intents |
| **Matrix** | Yes | Full support |
| **WhatsApp** | Yes (via whatsmeow) | Same ban risk as Baileys |
| **MS Teams** | Yes | Bot Framework integration |
| **SimpleX** | Custom adapter needed | Requires bridge bot process |
| **Google Chat** | No | Custom gateway needed |
| **iMessage** | No | Custom BlueBubbles bridge possible |
| **Nostr** | No | Custom gateway needed |
| **XMTP** | No | Custom gateway needed |
| **Nextcloud Talk** | Yes | Native support |
| **Urbit** | No | Custom HTTP API bridge needed |
| **Bitchat** | No | Not feasible (BLE only) |

**Privacy warning**: When bridging an E2E platform (Signal, SimpleX) to a non-E2E platform (Slack, Discord), messages from the encrypted side are stored unencrypted on the non-E2E platform's servers. Users on the encrypted side should be informed of this degradation.

## Related

- `tools/security/opsec.md` -- Threat modeling, platform trust matrix, network privacy
- `services/communications/simplex.md` -- SimpleX Chat (maximum privacy)
- `services/communications/signal.md` -- Signal (mainstream E2E gold standard)
- `services/communications/matrix-bot.md` -- Matrix bot integration
- `services/communications/telegram.md` -- Telegram bot integration
- `services/communications/whatsapp.md` -- WhatsApp bot integration
- `services/communications/imessage.md` -- iMessage/BlueBubbles integration
- `services/communications/nostr.md` -- Nostr decentralized messaging
- `services/communications/slack.md` -- Slack bot integration
- `services/communications/discord.md` -- Discord bot integration
- `services/communications/google-chat.md` -- Google Chat integration
- `services/communications/msteams.md` -- Microsoft Teams integration
- `services/communications/nextcloud-talk.md` -- Nextcloud Talk integration
- `services/communications/urbit.md` -- Urbit personal server messaging
- `services/communications/bitchat.md` -- Bitchat BLE mesh messaging
- `services/communications/xmtp.md` -- XMTP wallet-native messaging
- `services/communications/matterbridge.md` -- Cross-platform bridging
