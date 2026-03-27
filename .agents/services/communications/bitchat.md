---
description: Bitchat — decentralized peer-to-peer messaging over Bluetooth mesh networks, no internet required, Noise Protocol encryption, multi-hop relay, iOS/Android/macOS
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Bitchat

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Decentralized P2P messaging over Bluetooth mesh — no internet, no servers, no phone numbers
- **License**: Unlicense (public domain)
- **Apps**: iOS 16.0+, Android 8.0+ (API 26), macOS 13.0+
- **Protocol**: Noise_XX_25519_ChaChaPoly_SHA256 (E2E encrypted)
- **Transport**: Bluetooth Low Energy (BLE), extensible to Wi-Fi Direct
- **Repo**: [github.com/permissionlesstech/bitchat](https://github.com/permissionlesstech/bitchat) (iOS/macOS, Swift)
- **Android repo**: [github.com/permissionlesstech/bitchat-android](https://github.com/permissionlesstech/bitchat-android)
- **Website**: [bitchat.free](https://bitchat.free/)
- **Whitepaper**: [WHITEPAPER.md](https://github.com/permissionlesstech/bitchat/blob/main/WHITEPAPER.md)

**When to use Bitchat vs other protocols**:

| Criterion | Bitchat | SimpleX | Matrix | XMTP |
|-----------|---------|---------|--------|------|
| Internet required | No | Yes | Yes | Yes |
| Transport | BLE mesh | SMP relays | Client-server | Decentralized nodes |
| User identifiers | Fingerprint (pubkey hash) | None | `@user:server` | Wallet/DID |
| Range | ~100m/hop, multi-hop relay | Global | Global | Global |
| Best for | Offline/local, censorship resistance | Max privacy | Team collab | Web3/agent messaging |

<!-- AI-CONTEXT-END -->

## Architecture

Devices form ad-hoc BLE mesh networks with four layers: Application (`BitchatMessage`) → Session (`BitchatPacket`, compact binary) → Encryption (Noise XX) → Transport (BLE). Each device acts as both endpoint and relay — messages hop through intermediaries (TTL-decremented) to extend range. No central coordinator; the network forms and dissolves as devices move.

**Message flow**: Sender serializes a `BitchatPacket` → Noise XX handshake (if needed) → encrypt with ChaCha20-Poly1305 → pad to block size (256/512/1024/2048 bytes, resists traffic analysis) → transmit over BLE → relay peers decrement TTL and forward → recipient decrypts → delivery ACK returns through mesh.

## Protocol

### Identity and Keys

Each device generates two persistent key pairs on first launch (stored in the device's secure keystore — Apple Keychain on iOS/macOS; Android Keystore on Android):

| Key | Algorithm | Purpose |
|-----|-----------|---------|
| Noise static key | Curve25519 | Long-term identity for Noise handshake |
| Signing key | Ed25519 | Signing announcements, binding pubkey to nickname |

**Fingerprint**: `SHA256(StaticPublicKey_Curve25519)` — used for out-of-band verification (QR code, read aloud).

### Packet Format

| Field | Size | Description |
|-------|------|-------------|
| Version | 1 byte | Protocol version (currently `1`) |
| Type | 1 byte | Message type (message, deliveryAck, handshake, etc.) |
| TTL | 1 byte | Mesh routing hop limit, decremented per hop |
| Timestamp | 8 bytes | Millisecond timestamp |
| Flags | 1 byte | Bitmask: hasRecipient, hasSignature, isCompressed |
| Payload Length | 2 bytes | Length of payload |
| Sender ID | 8 bytes | Truncated peer ID |
| Recipient ID | 8 bytes (opt) | Truncated peer ID, or `0xFF..FF` for broadcast |
| Payload | Variable | Message content |
| Signature | 64 bytes (opt) | Ed25519 signature |

All packets padded to next block size (PKCS#7-style) to obscure true message length.

### Social Trust

- **Peer verification**: Out-of-band fingerprint comparison, marked "verified" locally
- **Favorites**: Prioritize trusted/frequent contacts
- **Blocking**: Discard packets from blocked fingerprints at earliest stage

## Installation

| Platform | Store | Source | Last verified |
|----------|-------|--------|---------------|
| iOS/macOS | [App Store](https://apps.apple.com/us/app/bitchat-mesh/id6748219622) | [bitchat](https://github.com/permissionlesstech/bitchat) (Xcode 15+, Swift) | 2026-03-27 |
| Android | [Play Store](https://play.google.com/store/apps/details?id=com.bitchat.droid) / [APK](https://github.com/permissionlesstech/bitchat-android/releases) | [bitchat-android](https://github.com/permissionlesstech/bitchat-android) (Gradle, API 26+) | 2026-03-27 |

No desktop Linux/Windows client. No CLI or bot API (native app only).

## Limitations

- **Range**: ~100m/hop open air, less indoors. Multi-hop extends range but adds latency.
- **Bandwidth**: BLE ~1 Mbps theoretical. Text messaging only — not file transfer. Padding reduces effective throughput.
- **Availability**: Requires physical proximity. No store-and-forward for offline recipients.
- **No programmatic API**: Unlike SimpleX or Matrix, no WebSocket/REST API. Integration requires a native bridge or upstream API support.

## Security

### Threat Model

| Protects against | Does NOT protect against |
|-----------------|--------------------------|
| Internet surveillance (no internet traffic) | Physical proximity attacks (BLE range observation) |
| Server compromise (no servers) | Device compromise (Keychain holds all keys) |
| Network censorship (requires physical jamming) | Bluetooth jamming (physical-layer DoS) |
| Traffic analysis (uniform padded packets) | Relay manipulation (can drop, not read, packets) |
| Identity correlation (pubkey hashes, no phone/email) | Sybil attacks (no cost to create mesh identities) |

### Operational Security

- Verify peer fingerprints out-of-band before trusting
- Use blocking to silence unwanted peers
- BLE advertising reveals device presence to nearby scanners

## Integration with aidevops

**Status**: No programmatic API — native app only. Direct integration with aidevops runners is not currently possible.

**Future possibilities**:

- **Native bridge**: macOS app bridging Bitchat to a local WebSocket (similar to SimpleX CLI bot API)
- **Matterbridge adapter**: If Bitchat adds CLI/API, bridge to Matrix/SimpleX/etc.
- **Offline dispatch**: Relay task results between devices when internet is unavailable

| Scenario | Value |
|----------|-------|
| Field operations | Relay AI-generated reports without internet |
| Protest/disaster comms | Censorship-resistant coordination |
| Air-gapped environments | Communicate between devices in secure facilities |
| Local mesh notifications | Alert nearby team members of deployment status |

## Related

- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, internet-based)
- `services/communications/matrix-bot.md` — Matrix bot integration (federated, internet-based)
- `services/communications/xmtp.md` — XMTP (Web3 messaging, internet-based)
- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `tools/security/opsec.md` — Operational security guidance
- Bitchat Whitepaper: https://github.com/permissionlesstech/bitchat/blob/main/WHITEPAPER.md
