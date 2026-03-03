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

# Nostr

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Decentralized relay-based messaging protocol — keypair identity, no phone/email required, censorship-resistant
- **License**: Public domain / MIT (protocol and most clients/libraries)
- **Protocol**: NIP-01 (events), NIP-04 (encrypted DMs, legacy), NIP-44 (versioned encryption), NIP-17 (gift-wrapped DMs)
- **Transport**: WebSocket connections to relay servers
- **SDK**: `nostr-tools` (npm, TypeScript) — event creation, signing, relay management, NIP implementations
- **Identity**: secp256k1 keypair — `nsec` (private key), `npub` (public key), NIP-19 bech32 encoding
- **Repo**: [github.com/nbd-wtf/nostr-tools](https://github.com/nbd-wtf/nostr-tools) | [github.com/nostr-protocol/nips](https://github.com/nostr-protocol/nips)
- **Relay list**: [nostr.watch](https://nostr.watch/) | [relay.tools](https://relay.tools/)
- **Clients**: Damus (iOS), Amethyst (Android), Primal (web/mobile), Snort (web), Coracle (web)

**Key differentiator**: Nostr is radically simple — the entire protocol is JSON events signed with secp256k1 keys, relayed over WebSockets. No accounts, no servers to run, no registration. Identity is a keypair. Anyone can run a relay. Censorship resistance comes from relay redundancy — if one relay drops your events, others still have them.

**When to use Nostr vs other protocols**:

| Criterion | Nostr | SimpleX | Matrix | XMTP | Bitchat |
|-----------|-------|---------|--------|------|---------|
| Identity model | secp256k1 keypair (npub) | None | `@user:server` | Wallet/DID | Pubkey fingerprint |
| Encryption (DMs) | NIP-04 (ECDH+AES), NIP-44 (XChaCha20) | Double ratchet (X3DH) | Megolm (optional) | MLS + post-quantum | Noise XX |
| Metadata privacy | Low (NIP-04), High (NIP-17) | High | Medium | Medium | High |
| Relay architecture | Redundant WebSocket relays | Stateless SMP relays | Federated servers | Decentralized nodes | BLE mesh |
| Bot/agent SDK | `nostr-tools` (TypeScript) | WebSocket JSON API | `matrix-bot-sdk` | `@xmtp/agent-sdk` | None |
| Native payments | Lightning Network (NIP-57 zaps) | No | No | In-conversation | No |
| Best for | Public social + private DMs, censorship resistance | Maximum privacy | Team collaboration | Web3/agent messaging | Offline/local comms |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────┐     ┌──────────────────────┐
│ Nostr Client          │     │ Nostr Client          │
│ (Damus, Amethyst,     │     │ (Primal, Snort,       │
│  Primal, or Bot)      │     │  Coracle, or Bot)     │
│                       │     │                       │
│ ┌──────────────────┐  │     │  ┌──────────────────┐ │
│ │ nostr-tools SDK  │  │     │  │ nostr-tools SDK  │ │
│ │ ├─ Event signing │  │     │  │ ├─ Event signing │ │
│ │ ├─ NIP-04/44 enc │  │     │  │ ├─ NIP-04/44 dec │ │
│ │ ├─ Relay pool    │  │     │  │ ├─ Relay pool    │ │
│ │ └─ Subscriptions │  │     │  │ └─ Subscriptions │ │
│ └──────────────────┘  │     │  └──────────────────┘ │
└──────────┬────────────┘     └──────────┬────────────┘
           │                             │
           │  WebSocket (wss://)         │
           │                             │
    ┌──────▼─────────────────────────────▼──────┐
    │           Nostr Relay Network              │
    │                                            │
    │  ┌──────────┐ ┌──────────┐ ┌──────────┐   │
    │  │ Relay 1  │ │ Relay 2  │ │ Relay 3  │   │
    │  │ (public) │ │ (paid)   │ │ (private)│   │
    │  └──────────┘ └──────────┘ └──────────┘   │
    │                                            │
    │  Independent operators, no coordination    │
    │  Events stored per relay policy            │
    └────────────────────────────────────────────┘
```

**Message flow (NIP-04 DM)**:

1. Sender generates shared secret via secp256k1 ECDH (sender privkey + recipient pubkey)
2. Message encrypted with AES-256-CBC using the shared secret
3. Encrypted content wrapped in a kind-4 event, signed with sender's privkey
4. Event published to sender's relay set via WebSocket
5. Recipient subscribes to kind-4 events addressed to their pubkey
6. Recipient decrypts using the same ECDH shared secret (recipient privkey + sender pubkey)

**Message flow (NIP-17 gift-wrapped DM)**:

1. Sender creates a kind-14 event (chat message) with NIP-44 encryption
2. Event wrapped in a kind-13 "seal" — encrypted to recipient, signed by sender
3. Seal wrapped in a kind-1059 "gift wrap" — signed by a random throwaway key
4. Gift wrap published to recipient's relay set
5. Relay sees only the throwaway key — sender pubkey, recipient pubkey, and timestamps are hidden
6. Recipient unwraps gift wrap, decrypts seal, reads the original message

## Protocol

### NIP-01: Basic Protocol

The foundation of Nostr — every piece of data is a signed JSON event:

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

### NIP-04: Encrypted Direct Messages (Legacy)

- **Encryption**: secp256k1 ECDH shared secret + AES-256-CBC
- **Event kind**: 4
- **Tags**: `["p", "<recipient-pubkey>"]`
- **Content**: `<base64-ciphertext>?iv=<base64-iv>`

**Limitations**:

- Sender and recipient pubkeys visible to relays (metadata leak)
- Timestamps visible (timing analysis possible)
- No forward secrecy — compromised key decrypts all past messages
- AES-256-CBC without authentication (no AEAD)
- Superseded by NIP-44 encryption + NIP-17 gift wrapping

### NIP-44: Versioned Encryption

- **Encryption**: XChaCha20-Poly1305 (AEAD) with secp256k1 ECDH + HKDF
- **Improvements over NIP-04**: Authenticated encryption, padding to resist length analysis, versioned for future algorithm upgrades
- **Used by**: NIP-17 gift-wrapped DMs, NIP-59 gift wraps

### NIP-17: Private Direct Messages (Gift-Wrapped)

- **Event kinds**: 14 (chat message), 13 (seal), 1059 (gift wrap)
- **Privacy**: Hides sender pubkey, recipient pubkey, and timestamps from relays
- **Encryption**: NIP-44 (XChaCha20-Poly1305)
- **Relay routing**: Published to recipient's NIP-65 relay list, not sender's

**Three-layer wrapping**:

1. **Kind 14** (rumor): The actual chat message, unsigned
2. **Kind 13** (seal): Rumor encrypted to recipient with NIP-44, signed by sender
3. **Kind 1059** (gift wrap): Seal encrypted to recipient, signed by random throwaway key with randomized timestamp

Relays see only the throwaway key and a randomized timestamp — no metadata about the actual conversation.

### NIP-65: Relay List Metadata

Users publish kind-10002 events listing their preferred relays (read, write, or both). Bots should read a recipient's NIP-65 relay list to know where to publish gift-wrapped DMs.

## Identity

### Keypair Model

Nostr identity is a secp256k1 keypair:

| Format | Prefix | Description |
|--------|--------|-------------|
| Hex pubkey | (none) | 32-byte hex, used in events |
| npub | `npub1...` | NIP-19 bech32-encoded public key (human-readable) |
| nsec | `nsec1...` | NIP-19 bech32-encoded private key (secret) |
| nprofile | `nprofile1...` | NIP-19 pubkey + relay hints |

**No registration, no server, no phone number.** Generate a keypair and you have an identity. The same keypair works across all Nostr clients and relays.

### Key Management for Bots

```bash
# Generate keypair (do NOT log or expose the nsec)
# Store nsec via gopass or credentials.sh (600 permissions)
aidevops secret set NOSTR_BOT_NSEC

# The npub is public — safe to share and configure
# Derive npub from nsec programmatically at runtime
```

**Security rules**:

- NEVER log, print, or expose the `nsec` private key
- Store via `gopass` (preferred) or `~/.config/aidevops/credentials.sh` (600 permissions)
- Derive the `npub` at runtime from the stored `nsec`
- Use a dedicated keypair for the bot — never reuse a personal identity

## Installation

### nostr-tools SDK

```bash
# Install SDK
npm install nostr-tools

# Or with Bun (faster)
bun add nostr-tools
```

**Bun compatibility**: nostr-tools is pure TypeScript with no native modules — fully compatible with Bun. Use `bun:sqlite` for local state if needed.

### Key Dependencies

| Package | Purpose |
|---------|---------|
| `nostr-tools` | Event creation, signing, relay management, NIP implementations |
| `@noble/secp256k1` | Cryptographic primitives (bundled with nostr-tools) |
| `websocket-polyfill` | WebSocket for Node.js (not needed with Bun) |

## Bot Implementation

### DM-Only Bot (Current Scope)

The aidevops Nostr bot operates in DM-only mode — it listens for encrypted direct messages from allowed pubkeys and dispatches to runners. It does not post publicly.

```typescript
import {
  generateSecretKey,
  getPublicKey,
  finalizeEvent,
  nip04,
  nip19,
  SimplePool,
} from "nostr-tools";

// Load bot private key from secure storage (never hardcode)
const sk = hexToBytes(process.env.NOSTR_BOT_SK_HEX!);
const pk = getPublicKey(sk);

console.log(`Bot pubkey: ${nip19.npubEncode(pk)}`);

// Allowed pubkeys (access control)
const ALLOWED_PUBKEYS = new Set(
  (process.env.NOSTR_ALLOWED_PUBKEYS || "").split(",").filter(Boolean)
);

// Connect to relays
const pool = new SimplePool();
const relays = [
  "wss://relay.damus.io",
  "wss://nos.lol",
  "wss://relay.nostr.band",
];

// Subscribe to kind-4 DMs addressed to this bot
const sub = pool.subscribeMany(
  relays,
  [{ kinds: [4], "#p": [pk], since: Math.floor(Date.now() / 1000) }],
  {
    onevent: async (event) => {
      // Access control: check sender pubkey
      if (!ALLOWED_PUBKEYS.has(event.pubkey)) {
        console.log(`Ignored DM from unauthorized pubkey: ${event.pubkey}`);
        return;
      }

      // Decrypt NIP-04 message
      const plaintext = await nip04.decrypt(sk, event.pubkey, event.content);
      console.log(`DM from ${event.pubkey}: ${plaintext}`);

      // Dispatch to aidevops runner
      const response = await dispatchToRunner(plaintext);

      // Encrypt and send reply
      const ciphertext = await nip04.encrypt(sk, event.pubkey, response);
      const replyEvent = finalizeEvent(
        {
          kind: 4,
          created_at: Math.floor(Date.now() / 1000),
          tags: [["p", event.pubkey]],
          content: ciphertext,
        },
        sk
      );

      await Promise.any(pool.publish(relays, replyEvent));
    },
  }
);
```

### Access Control via Pubkey Allowlist

The bot only processes DMs from pubkeys in the allowlist. This is the primary access control mechanism.

```bash
# Environment variable: comma-separated hex pubkeys
NOSTR_ALLOWED_PUBKEYS="<hex-pubkey-1>,<hex-pubkey-2>"

# Or store in config
# ~/.config/aidevops/nostr-bot.json (600 permissions)
```

**Config file format**:

```json
{
  "botSkHex": "DO_NOT_STORE_HERE_USE_GOPASS",
  "allowedPubkeys": [
    "abc123...",
    "def456..."
  ],
  "relays": [
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.nostr.band"
  ],
  "dmProtocol": "nip-04",
  "responseTimeout": 600
}
```

**Note**: The `botSkHex` field should reference a gopass secret or environment variable, not contain the actual key. The config template shows the field for documentation; the actual implementation reads from `NOSTR_BOT_SK_HEX` env var or `aidevops secret get NOSTR_BOT_SK_HEX`.

### NIP-17 Gift-Wrapped DMs (Planned)

NIP-17 provides metadata-private DMs. Implementation requires:

1. Read recipient's NIP-65 relay list to find their inbox relays
2. Create kind-14 rumor (unsigned chat message)
3. Wrap in kind-13 seal (NIP-44 encrypted to recipient, signed by bot)
4. Wrap in kind-1059 gift wrap (NIP-44 encrypted to recipient, signed by throwaway key)
5. Publish gift wrap to recipient's inbox relays

nostr-tools provides `nip44` and `nip59` modules for this. Migration from NIP-04 to NIP-17 is recommended when client support is widespread.

## Relay Architecture

### How Relays Work

- Relays are WebSocket servers that store and forward Nostr events
- Anyone can run a relay — no permission or coordination needed
- Each relay has its own storage policy (retention, size limits, paid/free)
- Clients connect to multiple relays for redundancy
- Events are identified by their SHA-256 hash — duplicates are idempotent

### Relay Selection for Bots

| Relay type | Use case | Examples |
|------------|----------|---------|
| Public free | Development, testing | `wss://relay.damus.io`, `wss://nos.lol` |
| Public paid | Production, reliability | `wss://relay.nostr.band` (freemium) |
| Private/self-hosted | Maximum control | Run your own `nostr-rs-relay` or `strfry` |

**Recommendations for bot deployment**:

- Use 3-5 relays for redundancy
- Include at least one paid relay for reliability
- Consider self-hosting a relay for full control over data retention
- Read recipients' NIP-65 relay lists to ensure delivery

### Self-Hosted Relay Options

| Software | Language | Notes |
|----------|----------|-------|
| [nostr-rs-relay](https://github.com/scsibug/nostr-rs-relay) | Rust | SQLite backend, lightweight |
| [strfry](https://github.com/hoytech/strfry) | C++ | High performance, LMDB backend |
| [nostream](https://github.com/Cameri/nostream) | TypeScript | PostgreSQL, Docker-ready |

## Deployment

### Process Management

```bash
# Using PM2
npm i -g pm2
pm2 start src/nostr-bot.ts --interpreter tsx --name nostr-bot
pm2 save
pm2 startup

# Using systemd (Linux)
# Create /etc/systemd/system/nostr-bot.service
# ExecStart=/usr/bin/bun run /opt/nostr-bot/src/bot.ts
# Environment=NOSTR_BOT_SK_HEX=<from-gopass>
```

### Docker

```dockerfile
FROM oven/bun:1-slim
WORKDIR /app
COPY package.json bun.lockb ./
RUN bun install --frozen-lockfile
COPY . .
CMD ["bun", "run", "src/bot.ts"]
```

**Environment variables** (passed via Docker secrets or env file):

| Variable | Required | Description |
|----------|----------|-------------|
| `NOSTR_BOT_SK_HEX` | Yes | Bot's secp256k1 private key (hex) |
| `NOSTR_ALLOWED_PUBKEYS` | Yes | Comma-separated hex pubkeys |
| `NOSTR_RELAYS` | No | Comma-separated relay URLs (defaults to public relays) |
| `NOSTR_DM_PROTOCOL` | No | `nip-04` (default) or `nip-17` |

## Privacy and Security Assessment

### Strengths

- **No phone/email required** — keypair identity only, no PII needed
- **Decentralized** — no single entity controls the network or can shut it down
- **Censorship-resistant** — events replicated across multiple independent relays
- **Open protocol** — anyone can build clients, relays, or tools
- **Lightning payments** — NIP-57 zaps enable native Bitcoin payments
- **No AI training risk from protocol** — the protocol itself doesn't collect data; individual relay operators set their own policies

### Weaknesses

- **NIP-04 metadata exposure** — sender pubkey, recipient pubkey, and timestamps visible to relays (use NIP-17 to mitigate)
- **No forward secrecy** — NIP-04 uses static ECDH; compromised key decrypts all past messages (NIP-44 improves but still no ratchet)
- **Relay trust** — relays see event metadata (pubkeys, timestamps, kinds) unless NIP-17 gift wrapping is used
- **Pubkey correlation** — the same pubkey is used across all interactions, enabling activity correlation across relays
- **No push notifications** — clients must poll relays or maintain persistent WebSocket connections
- **Key management burden** — losing the nsec means losing the identity permanently; no recovery mechanism

### Threat Model

Nostr protects against:

- **Platform deplatforming** — no single entity can ban a pubkey from the network
- **Server seizure** — events exist on multiple independent relays
- **Censorship** — relay redundancy means censoring requires blocking all relays
- **Identity theft** — secp256k1 signatures are cryptographically unforgeable

Nostr does **not** protect against:

- **Metadata analysis (NIP-04)** — relays see who talks to whom and when
- **Key compromise** — all past NIP-04 DMs decryptable with the private key
- **Relay collusion** — relays could share metadata to build social graphs
- **Sybil attacks** — creating fake identities is free (no proof of work or stake)
- **Spam** — open protocol means anyone can send events; filtering is client-side

### Comparison with SimpleX Privacy

| Aspect | Nostr (NIP-04) | Nostr (NIP-17) | SimpleX |
|--------|---------------|----------------|---------|
| Sender identity visible to relay | Yes | No (throwaway key) | No (stateless) |
| Recipient identity visible to relay | Yes | No (encrypted) | No (queue-based) |
| Timestamps visible | Yes | No (randomized) | No (memory-only) |
| Forward secrecy | No | No | Yes (double ratchet) |
| User identifiers | Pubkey (persistent) | Pubkey (hidden in transit) | None |

**Recommendation**: For maximum DM privacy on Nostr, use NIP-17 gift-wrapped messages. For maximum privacy overall, SimpleX remains stronger due to its lack of persistent identifiers and double-ratchet forward secrecy.

## Limitations

### No Forward Secrecy

Neither NIP-04 nor NIP-44 implements a ratcheting protocol. A compromised private key can decrypt all past encrypted messages. This is a fundamental limitation compared to Signal/SimpleX double-ratchet protocols.

### Metadata Exposure (NIP-04)

NIP-04 DMs expose sender pubkey, recipient pubkey, and timestamps to every relay that stores the event. NIP-17 mitigates this but requires client support on both sides.

### Relay Dependence

While decentralized, the bot depends on relays being online and storing events. Free public relays may have aggressive retention policies or rate limits. Paid or self-hosted relays provide more reliability.

### No Offline Support

Nostr requires internet connectivity to relay servers. Unlike Bitchat, there is no mesh or offline capability.

### Key Recovery

There is no key recovery mechanism. If the bot's `nsec` is lost, the identity is permanently lost. Backup the key securely.

### Client Ecosystem Fragmentation

NIP-17 support varies across clients. Some clients only support NIP-04 DMs. The bot should support both protocols and prefer NIP-17 when the recipient's client supports it.

### No Native Group DMs (Yet)

NIP-17 supports group DMs by including multiple `p` tags, but client support is inconsistent. For group coordination, consider using NIP-28 public channels or a different protocol.

## Integration with aidevops

### Bot Architecture

```text
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ Nostr Client      │     │ Nostr Bot        │     │ aidevops Runner  │
│ (Damus, Amethyst, │     │ (Bun/Node.js)    │     │                  │
│  Primal, etc.)    │     │                  │     │ runner-helper.sh │
│                   │────▶│ 1. Receive DM    │────▶│ → AI session     │
│ User sends DM:    │     │ 2. Check pubkey  │     │ → response       │
│ "Review auth.ts"  │◀────│ 3. Decrypt       │◀────│                  │
│                   │     │ 4. Dispatch      │     │                  │
│ AI response DM    │     │ 5. Encrypt reply │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Potential Components

| Component | File | Description |
|-----------|------|-------------|
| Subagent doc | `.agents/services/communications/nostr.md` | This file (t1385.5) |
| Helper script | `.agents/scripts/nostr-helper.sh` | Setup, key management, relay config |
| Bot process | `.agents/scripts/nostr-bot/` (TypeScript/Bun) | DM listener + runner dispatch |

### Matterbridge Integration

Nostr does not have a native Matterbridge adapter. A custom adapter could bridge Nostr DMs or public channels to other platforms via Matterbridge's REST API, following the same pattern as the SimpleX adapter (`matterbridge-simplex`).

### Use Cases for aidevops

| Scenario | Value |
|----------|-------|
| Censorship-resistant dispatch | Send commands to AI runners from any Nostr client, anywhere |
| Lightning-integrated bots | Accept zap payments for premium AI services |
| Cross-client access | Same bot reachable from Damus, Amethyst, Primal, or any NIP-04/17 client |
| Pseudonymous operations | Operate AI runners without revealing real identity |
| Decentralized notifications | Bot publishes status updates to followers (kind-1 notes) |

## Related

- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, strongest DM privacy)
- `services/communications/matrix-bot.md` — Matrix bot integration (federated, mature ecosystem)
- `services/communications/xmtp.md` — XMTP (Web3 messaging, wallet identity)
- `services/communications/bitchat.md` — Bitchat (Bluetooth mesh, offline)
- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `tools/security/opsec.md` — Operational security guidance
- Nostr NIPs: https://github.com/nostr-protocol/nips
- nostr-tools: https://github.com/nbd-wtf/nostr-tools
- Nostr relay list: https://nostr.watch/
