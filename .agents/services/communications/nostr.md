---
description: Nostr — decentralized relay-based messaging protocol with keypair identity, NIP-01 events, NIP-04/NIP-44 encrypted DMs, NIP-17 gift-wrapped DMs, nostr-tools SDK (TypeScript), DM-only bot scope, pubkey allowlist access control
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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Nostr

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Decentralized relay-based messaging — keypair identity, censorship-resistant
- **Protocol**: NIP-01 (events), NIP-04 (encrypted DMs, legacy), NIP-44 (versioned encryption), NIP-17 (gift-wrapped DMs)
- **Transport**: WebSocket connections to relay servers
- **SDK**: `nostr-tools` (npm, TypeScript) — event creation, signing, relay management, NIP implementations
- **Identity**: secp256k1 keypair — `nsec` (private), `npub` (public), NIP-19 bech32 encoding
- **Repo**: [nbd-wtf/nostr-tools](https://github.com/nbd-wtf/nostr-tools) | [nostr-protocol/nips](https://github.com/nostr-protocol/nips)
- **Relay list**: [nostr.watch](https://nostr.watch/) | [relay.tools](https://relay.tools/)
- **Clients**: Damus (iOS), Amethyst (Android), Primal (web/mobile), Snort (web), Coracle (web)

### Protocol Comparison

| Criterion | Nostr | SimpleX | Matrix | XMTP | Bitchat |
|-----------|-------|---------|--------|------|---------|
| Identity | secp256k1 keypair | None | `@user:server` | Wallet/DID | Pubkey fingerprint |
| DM encryption | NIP-04 (AES-CBC), NIP-44 (XChaCha20) | Double ratchet | Megolm (optional) | MLS + post-quantum | Noise XX |
| Metadata privacy | Low (NIP-04), High (NIP-17) | High | Medium | Medium | High |
| Relay model | Redundant WebSocket | Stateless SMP | Federated | Decentralized nodes | BLE mesh |
| Bot SDK | `nostr-tools` (TS) | WebSocket JSON API | `matrix-bot-sdk` | `@xmtp/agent-sdk` | None |
| Native payments | Lightning (NIP-57 zaps) | No | No | In-conversation | No |
| Best for | Public social + private DMs | Maximum privacy | Team collaboration | Web3/agent messaging | Offline/local |

<!-- AI-CONTEXT-END -->

## Protocol

### NIP-01: Basic Protocol

Every piece of data is a signed JSON event:

```json
{
  "id": "<32-byte SHA-256 hex of serialized event>",
  "pubkey": "<32-byte secp256k1 pubkey hex of creator>",
  "created_at": 1234567890,
  "kind": 1,
  "tags": [["p", "<pubkey>"], ["e", "<event-id>"]],
  "content": "Hello Nostr!",
  "sig": "<64-byte Schnorr signature hex>"
}
```

**Event kinds relevant to bots**:

| Kind | NIP | Description |
|------|-----|-------------|
| 0 | NIP-01 | Metadata (profile name, about, picture) |
| 1 | NIP-01 | Short text note (public post) |
| 4 | NIP-04 | Encrypted direct message (legacy) |
| 14 | NIP-17 | Chat message (gift-wrapped DM, preferred) |
| 9735 | NIP-57 | Zap receipt (Lightning payment) |
| 10002 | NIP-65 | Relay list metadata |

### NIP-04: Encrypted DMs (Legacy)

secp256k1 ECDH shared secret + AES-256-CBC; event kind 4. Sender/recipient pubkeys and timestamps visible to relays. No forward secrecy, no AEAD. Superseded by NIP-44 + NIP-17.

### NIP-44: Versioned Encryption

XChaCha20-Poly1305 (AEAD) with secp256k1 ECDH + HKDF. Authenticated encryption, padding to resist length analysis, versioned for future upgrades. Used by NIP-17 gift-wrapped DMs.

### NIP-17: Private Direct Messages (Gift-Wrapped)

Three-layer wrapping hides sender, recipient, and timestamps from relays:

1. **Kind 14** (rumor): Actual chat message, unsigned
2. **Kind 13** (seal): Rumor encrypted to recipient with NIP-44, signed by sender
3. **Kind 1059** (gift wrap): Seal encrypted to recipient, signed by random throwaway key with randomized timestamp

Published to recipient's NIP-65 relay list, not sender's.

### NIP-65: Relay List Metadata

Users publish kind-10002 events listing preferred relays. Bots should read a recipient's NIP-65 list to know where to publish gift-wrapped DMs.

## Identity

| Format | Prefix | Description |
|--------|--------|-------------|
| Hex pubkey | (none) | 32-byte hex, used in events |
| npub | `npub1...` | NIP-19 bech32-encoded public key |
| nsec | `nsec1...` | NIP-19 bech32-encoded private key (secret) |
| nprofile | `nprofile1...` | NIP-19 pubkey + relay hints |

No registration, no server, no phone number. Same keypair works across all clients and relays.

### Key Management for Bots

```bash
# Store nsec via gopass — NEVER log or expose the nsec
aidevops secret set NOSTR_BOT_NSEC
# Derive npub at runtime from the stored nsec
```

**Rules**: NEVER log/print/expose the `nsec`. Use a dedicated keypair for the bot — never reuse a personal identity.

## Installation

```bash
npm install nostr-tools   # or: bun add nostr-tools
```

Pure TypeScript, fully compatible with Bun. `@noble/secp256k1` bundled. Node.js requires `websocket-polyfill`; Bun does not.

## Bot Implementation

### DM-Only Bot (Current Scope)

Listens for encrypted DMs from allowed pubkeys, dispatches to runners. Does not post publicly.

```typescript
import {
  generateSecretKey, getPublicKey, finalizeEvent,
  nip04, nip19, SimplePool,
} from "nostr-tools";

// Load bot private key from secure storage (never hardcode)
const botNsec = process.env.NOSTR_BOT_NSEC;
if (!botNsec) throw new Error("NOSTR_BOT_NSEC not set");
const { data: sk } = nip19.decode(botNsec) as { data: Uint8Array };
const pk = getPublicKey(sk);

// Allowed pubkeys (access control)
const ALLOWED_PUBKEYS = new Set(
  (process.env.NOSTR_ALLOWED_PUBKEYS || "").split(",").filter(Boolean)
);

const pool = new SimplePool();
const relays = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.nostr.band"];

const sub = pool.subscribeMany(
  relays,
  [{ kinds: [4], "#p": [pk], since: Math.floor(Date.now() / 1000) }],
  {
    onevent: async (event) => {
      if (!ALLOWED_PUBKEYS.has(event.pubkey)) return;

      const plaintext = await nip04.decrypt(sk, event.pubkey, event.content);
      const response = await dispatchToRunner(plaintext);

      const ciphertext = await nip04.encrypt(sk, event.pubkey, response);
      const replyEvent = finalizeEvent({
        kind: 4,
        created_at: Math.floor(Date.now() / 1000),
        tags: [["p", event.pubkey]],
        content: ciphertext,
      }, sk);

      await Promise.any(pool.publish(relays, replyEvent));
    },
  }
);
```

### Access Control

```bash
# Environment variable: comma-separated hex pubkeys
NOSTR_ALLOWED_PUBKEYS="<hex-pubkey-1>,<hex-pubkey-2>"
```

```json
{
  "botNsecPath": "aidevops/nostr-bot/nsec",
  "allowedPubkeys": ["abc123...", "def456..."],
  "relays": ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.nostr.band"],
  "dmProtocol": "nip-04",
  "responseTimeout": 600
}
```

`botNsecPath` is a gopass path — the actual `nsec` is never written to disk.

### NIP-17 Gift-Wrapped DMs (Planned)

Migration from NIP-04 to NIP-17 recommended when client support is widespread. nostr-tools provides `nip44` and `nip59` modules. Flow: read recipient's NIP-65 relay list -> create kind-14 rumor -> kind-13 seal -> kind-1059 gift wrap -> publish to recipient's inbox relays.

## Relay Architecture

Use 3-5 relays for redundancy; include at least one paid relay. Events identified by SHA-256 hash — duplicates are idempotent.

| Type | Use case | Examples |
|------|----------|---------|
| Public free | Development, testing | `wss://relay.damus.io`, `wss://nos.lol` |
| Public paid | Production, reliability | `wss://relay.nostr.band` (freemium) |
| Self-hosted | Maximum control | `nostr-rs-relay` (Rust/SQLite), `strfry` (C++/LMDB), `nostream` (TS/PostgreSQL) |

## Deployment

```bash
# PM2
pm2 start src/nostr-bot.ts --interpreter tsx --name nostr-bot && pm2 save && pm2 startup
```

```dockerfile
FROM oven/bun:1-slim
WORKDIR /app
COPY package.json bun.lockb ./
RUN bun install --frozen-lockfile
COPY . .
CMD ["bun", "run", "src/bot.ts"]
```

| Variable | Required | Description |
|----------|----------|-------------|
| `NOSTR_BOT_SK_HEX` | Yes | Bot's secp256k1 private key (hex) |
| `NOSTR_ALLOWED_PUBKEYS` | Yes | Comma-separated hex pubkeys |
| `NOSTR_RELAYS` | No | Comma-separated relay URLs |
| `NOSTR_DM_PROTOCOL` | No | `nip-04` (default) or `nip-17` |

## Privacy and Security

| Issue | NIP-04 | NIP-17 | Mitigation |
|-------|--------|--------|------------|
| Sender/recipient visible to relays | Yes | No (throwaway key) | Use NIP-17 |
| Timestamps visible | Yes | No (randomized) | Use NIP-17 |
| Forward secrecy | No | No | Use SimpleX for max privacy |
| Key recovery | None | None | Backup nsec securely |
| Offline support | No | No | Requires internet to relays |
| Group DMs | No | Partial (inconsistent client support) | — |
| Spam filtering | Client-side only | Client-side only | — |

**No forward secrecy**: Neither NIP-04 nor NIP-44 implements a ratcheting protocol. Compromised private key decrypts all past messages.

**Threat model**: Protects against platform deplatforming, server seizure, censorship (relay redundancy), identity theft (secp256k1 signatures). Does NOT protect against metadata analysis (NIP-04), key compromise (all past NIP-04 DMs decryptable), relay collusion, sybil attacks, spam.

## Integration with aidevops

```text
Nostr Client -> Nostr Bot (Bun/Node.js) -> aidevops Runner
               1. Receive DM              runner-helper.sh
               2. Check pubkey         -> AI session -> response
               3. Decrypt/dispatch
               4. Encrypt reply
```

| Component | File | Description |
|-----------|------|-------------|
| Subagent doc | `.agents/services/communications/nostr.md` | This file (t1385.5) |
| Helper script | `.agents/scripts/nostr-helper.sh` | Setup, key management, relay config |
| Bot process | `.agents/scripts/nostr-bot/` (TypeScript/Bun) | DM listener + runner dispatch |

**Matterbridge**: No native adapter. Custom adapter could bridge Nostr DMs via Matterbridge's REST API.

**Use cases**: Censorship-resistant dispatch, Lightning-integrated bots (NIP-57 zaps), cross-client access, pseudonymous operations, decentralized status notifications.

## Related

- `services/communications/simplex.md` — SimpleX (zero-knowledge, strongest DM privacy)
- `services/communications/matrix-bot.md` — Matrix bot (federated, mature ecosystem)
- `services/communications/xmtp.md` — XMTP (Web3 messaging, wallet identity)
- `services/communications/bitchat.md` — Bitchat (Bluetooth mesh, offline)
- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `tools/security/opsec.md` — Operational security guidance
- Nostr NIPs: https://github.com/nostr-protocol/nips
- nostr-tools: https://github.com/nbd-wtf/nostr-tools
- Nostr relay list: https://nostr.watch/
