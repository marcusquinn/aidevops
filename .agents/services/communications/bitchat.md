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

**Key differentiator**: Bitchat operates entirely without internet infrastructure. Devices form ad-hoc Bluetooth mesh networks, relaying messages across multiple hops. This makes it uniquely suited for protests, natural disasters, remote areas, or any scenario where internet connectivity is unavailable, monitored, or disabled.

**When to use Bitchat vs other protocols**:

| Criterion | Bitchat | SimpleX | Matrix | XMTP |
|-----------|---------|---------|--------|------|
| Internet required | No | Yes | Yes | Yes |
| Transport | BLE mesh | SMP relays | Client-server | Decentralized nodes |
| User identifiers | Fingerprint (pubkey hash) | None | `@user:server` | Wallet/DID |
| Range | Physical proximity (~100m per hop, multi-hop relay) | Global | Global | Global |
| Best for | Offline/local comms, censorship resistance | Maximum privacy | Team collaboration | Web3/agent messaging |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────┐     ┌──────────────────────┐
│ Device A              │     │ Device B              │
│ (iOS/Android/macOS)   │     │ (iOS/Android/macOS)   │
│                       │     │                       │
│ ┌──────────────────┐  │     │  ┌──────────────────┐ │
│ │ Application Layer│  │     │  │ Application Layer│ │
│ │ BitchatMessage   │  │     │  │ BitchatMessage   │ │
│ ├──────────────────┤  │     │  ├──────────────────┤ │
│ │ Session Layer    │  │     │  │ Session Layer    │ │
│ │ BitchatPacket    │  │     │  │ BitchatPacket    │ │
│ ├──────────────────┤  │     │  ├──────────────────┤ │
│ │ Encryption Layer │  │     │  │ Encryption Layer │ │
│ │ Noise XX         │  │     │  │ Noise XX         │ │
│ ├──────────────────┤  │     │  ├──────────────────┤ │
│ │ Transport Layer  │  │     │  │ Transport Layer  │ │
│ │ BLE              │  │     │  │ BLE              │ │
│ └──────────────────┘  │     │  └──────────────────┘ │
└──────────┬───────────┘     └──────────┬───────────┘
           │                            │
           │  Bluetooth Low Energy      │
           │  (multi-hop mesh relay)    │
           └────────────────────────────┘
                       │
              ┌────────▼────────┐
              │ Device C (relay) │
              │ Decrements TTL,  │
              │ forwards packet  │
              └─────────────────┘
```

**Message flow**:

1. Sender composes message, serialized as `BitchatPacket` (compact binary format)
2. Noise XX handshake establishes E2E encrypted session (if not already active)
3. Packet encrypted with ChaCha20-Poly1305 via Noise transport cipher
4. Packet padded to standard block size (256/512/1024/2048 bytes) to resist traffic analysis
5. Transmitted over BLE to nearby peers
6. Relay peers decrement TTL and forward to their neighbors (multi-hop)
7. Recipient decrypts with their Noise session cipher
8. Delivery acknowledgment sent back through the mesh

## Protocol

### Noise Protocol

Bitchat uses **Noise_XX_25519_ChaChaPoly_SHA256**:

- **XX pattern**: Mutual authentication without prior key knowledge — ideal for ad-hoc P2P
- **Curve25519**: Diffie-Hellman key exchange
- **ChaCha20-Poly1305**: AEAD cipher for transport encryption
- **SHA-256**: Cryptographic hashing

The XX handshake is a 3-message exchange providing:

- **Forward secrecy**: Compromise of long-term keys does not compromise past sessions
- **Mutual authentication**: Both parties verify each other's identity
- **Deniability**: Difficult to cryptographically prove a specific user sent a message

### Identity and Keys

Each device generates two persistent key pairs on first launch, stored in the device Keychain:

| Key | Algorithm | Purpose |
|-----|-----------|---------|
| Noise static key | Curve25519 | Long-term identity for Noise handshake |
| Signing key | Ed25519 | Signing announcements, binding pubkey to nickname |

**Fingerprint**: `SHA256(StaticPublicKey_Curve25519)` — used for out-of-band identity verification (QR code, read aloud).

### Packet Format

Compact binary format minimizing bandwidth:

| Field | Size | Description |
|-------|------|-------------|
| Version | 1 byte | Protocol version (currently `1`) |
| Type | 1 byte | Message type (message, deliveryAck, handshake, etc.) |
| TTL | 1 byte | Time-to-live for mesh routing, decremented per hop |
| Timestamp | 8 bytes | Millisecond timestamp |
| Flags | 1 byte | Bitmask: hasRecipient, hasSignature, isCompressed |
| Payload Length | 2 bytes | Length of payload |
| Sender ID | 8 bytes | Truncated peer ID |
| Recipient ID | 8 bytes (optional) | Truncated peer ID, or `0xFF..FF` for broadcast |
| Payload | Variable | Message content |
| Signature | 64 bytes (optional) | Ed25519 signature |

All packets padded to next block size (PKCS#7-style) to obscure true message length.

### Social Trust Layer

- **Peer verification**: Out-of-band fingerprint comparison, marked as "verified" locally
- **Favorites**: Prioritize trusted/frequent contacts
- **Blocking**: Discard packets from blocked fingerprints at earliest stage

## Installation

### iOS / macOS

**App Store**: [Bitchat Mesh](https://apps.apple.com/us/app/bitchat-mesh/id6748219622)

**Build from source**:

```bash
git clone https://github.com/permissionlesstech/bitchat.git
cd bitchat

# Build with Xcode (requires Xcode 15+)
# Open in Xcode or use xcodegen/SPM
xcodebuild -scheme BitChat -destination 'platform=iOS Simulator'
```

Requires iOS 16.0+ or macOS 13.0+.

### Android

**Play Store**: [Bitchat](https://play.google.com/store/apps/details?id=com.bitchat.droid)

**APK releases**: [GitHub Releases](https://github.com/permissionlesstech/bitchat-android/releases)

**Build from source**:

```bash
git clone https://github.com/permissionlesstech/bitchat-android.git
cd bitchat-android

# Build with Gradle (requires Android SDK, API 26+)
./gradlew assembleDebug
```

Requires Android 8.0+ (API 26). Full protocol compatibility with iOS version.

## Usage

### Basic Operation

1. Install the app on two or more devices
2. Enable Bluetooth on all devices
3. Devices automatically discover peers via BLE advertising
4. Tap a discovered peer to initiate Noise handshake
5. Exchange messages — they relay through intermediate devices if needed

### Mesh Networking

- Each device acts as both client and relay
- Messages hop through intermediate devices to extend range
- TTL field prevents infinite relay loops
- No central coordinator — fully ad-hoc topology
- Network forms and dissolves as devices enter/leave proximity

### Broadcast vs Direct

- **Direct message**: Recipient ID set to target peer's truncated ID
- **Broadcast**: Recipient ID set to `0xFF..FF`, delivered to all peers in range

## Limitations

### Range

BLE range is approximately 100 meters per hop in open air, significantly less indoors or in dense environments. Multi-hop relay extends effective range but adds latency.

### Bandwidth

BLE throughput is limited (~1 Mbps theoretical, lower in practice). Bitchat is designed for text messaging, not file transfer. Packet padding further reduces effective throughput.

### Availability

Communication requires physical proximity. Unlike internet-based protocols, messages cannot be delivered when the recipient is out of mesh range. There is no store-and-forward mechanism for offline recipients.

### Platform

- iOS/macOS: Swift, requires Xcode to build
- Android: Kotlin/Java, requires Android SDK
- No desktop Linux/Windows client currently
- No CLI or bot API (native app only)

### No Bot API

Unlike SimpleX or Matrix, Bitchat has no WebSocket/REST API for programmatic access. Integration with aidevops would require building a native bridge or waiting for upstream API support.

## Security Considerations

### Threat Model

Bitchat protects against:

- **Internet surveillance**: No internet traffic to monitor
- **Server compromise**: No servers exist
- **Network censorship**: Cannot block Bluetooth mesh without physical jamming
- **Traffic analysis**: Packet padding and uniform sizes resist analysis
- **Identity correlation**: Fingerprints are pubkey hashes, no phone/email required

Bitchat does **not** protect against:

- **Physical proximity attacks**: Attacker within BLE range can observe encrypted traffic
- **Device compromise**: Local Keychain contains all keys
- **Bluetooth jamming**: Physical-layer denial of service
- **Relay manipulation**: Malicious relay nodes can drop (but not read) packets
- **Sybil attacks**: No cost to creating multiple identities in the mesh

### Operational Security

- Verify peer fingerprints out-of-band before trusting
- Use blocking to silence unwanted peers
- Be aware that BLE advertising reveals device presence to nearby observers
- Bitchat does not hide the fact that you are running the app from nearby BLE scanners

## Integration with aidevops

### Current Status

Bitchat has no programmatic API — it is a native mobile/desktop app only. Direct integration with aidevops runners is not currently possible.

### Future Possibilities

- **Native bridge**: A macOS app could bridge Bitchat messages to a local WebSocket, similar to how SimpleX CLI exposes its bot API
- **Matterbridge adapter**: If Bitchat adds a CLI or API, a Matterbridge adapter could bridge it to Matrix/SimpleX/etc.
- **Offline dispatch**: For field scenarios, Bitchat could relay task results between devices when internet is unavailable

### Use Cases for aidevops

| Scenario | Value |
|----------|-------|
| Field operations | Relay AI-generated reports between devices without internet |
| Protest/disaster comms | Censorship-resistant messaging for coordination |
| Air-gapped environments | Communicate between devices in secure facilities |
| Local mesh notifications | Alert nearby team members of deployment status |

## Related

- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, internet-based)
- `services/communications/matrix-bot.md` — Matrix bot integration (federated, internet-based)
- `services/communications/xmtp.md` — XMTP (Web3 messaging, internet-based)
- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `tools/security/opsec.md` — Operational security guidance
- Bitchat Whitepaper: https://github.com/permissionlesstech/bitchat/blob/main/WHITEPAPER.md
