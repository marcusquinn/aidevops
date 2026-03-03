---
description: Nostr — decentralized relay-based protocol, bot integration via nostr-tools (TypeScript), NIP-01 events, NIP-04/NIP-44 encrypted DMs, keypair identity, censorship-resistant messaging, and limitations
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

# Nostr Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Decentralized protocol — censorship-resistant, relay-based
- **License**: Protocol is open (no license needed), nostr-tools (MIT)
- **Bot tool**: nostr-tools (TypeScript, npm)
- **Protocol**: Nostr (Notes and Other Stuff Transmitted by Relays) — NIP-01 events over WebSocket
- **Encryption**: NIP-04 DMs (secp256k1 ECDH + AES-256-CBC), NIP-44 (improved, versioned encryption)
- **Identity**: Keypair-based (nsec/npub) — no phone, no email, no server account
- **NIPs**: https://github.com/nostr-protocol/nips (protocol specification)
- **nostr-tools**: https://github.com/nbd-wtf/nostr-tools
- **Relay list**: https://nostr.watch/

**Key differentiator**: Nostr requires no account creation, no phone number, no email, no server registration. Identity is a cryptographic keypair. Anyone can run a relay. No single entity can censor or deplatform a user. This makes it the strongest option for censorship-resistant, pseudonymous communication.

**When to use Nostr over other protocols**:

| Criterion | Nostr | SimpleX | Matrix |
|-----------|-------|---------|--------|
| Identity | Keypair (nsec/npub) | None (pairwise) | `@user:server` |
| Censorship resistance | Strongest (multi-relay) | Strong (no central server) | Moderate (federated) |
| Metadata privacy | Weak (relay sees pubkeys) | Strongest (no IDs) | Moderate |
| PII required | None | None | Optional but common |
| Bot ecosystem | Growing (nostr-tools) | Growing (WebSocket API) | Mature (SDK, bridges) |
| Message persistence | Relay-dependent | None (ephemeral) | Full history |
| Best for | Censorship resistance, pseudonymous comms | Maximum privacy, agent-to-agent | Team collaboration, bridges |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────────┐
│ Nostr Clients             │
│ (Damus, Amethyst, Primal, │
│  Snort, Coracle, etc.)    │
└──────────┬───────────────┘
           │ NIP-01 Events (JSON over WebSocket)
           │ Signed with secp256k1 keypair
           │
┌──────────▼───────────────┐     ┌──────────────────────────┐
│ Nostr Relays              │     │ Additional Relays         │
│ (wss://relay.damus.io,    │     │ (redundancy, reach)       │
│  wss://nos.lol, etc.)     │     │ Self-hosted relay option   │
└──────────┬───────────────┘     └──────────────────────────┘
           │
           │ Bot subscribes to events
           │ (filters: DMs to bot pubkey,
           │  mentions, specific kinds)
           │
┌──────────▼───────────────┐
│ Bot Process               │
│ (TypeScript/Bun)          │
│                           │
│ ├─ Relay pool manager     │
│ ├─ DM decryption (NIP-04/ │
│ │   NIP-44)               │
│ ├─ Command router         │
│ ├─ Pubkey allowlist       │
│ └─ aidevops dispatch      │
└───────────────────────────┘
```

**Message flow**: User encrypts DM (NIP-04/NIP-44) → signs event (secp256k1) → publishes to relays → bot subscribes with filter for kind 4 events to its pubkey → decrypts → processes → publishes encrypted response.

## Installation

### nostr-tools Setup (TypeScript/Bun)

```bash
mkdir nostr-bot && cd nostr-bot
bun init -y
bun add nostr-tools
```

### Key Generation

```typescript
import { generateSecretKey, getPublicKey, nip19 } from "nostr-tools"

const sk = generateSecretKey() // Uint8Array (32 bytes)
const pk = getPublicKey(sk)    // hex string
const nsec = nip19.nsecEncode(sk) // nsec1... (NEVER log in production)
const npub = nip19.npubEncode(pk) // npub1...
```

**Key storage**: Use `gopass` or environment variables — never commit to source control. See `.agents/tools/credentials/gopass.md`.

```bash
gopass insert aidevops/nostr-bot/nsec   # preferred
export NOSTR_BOT_NSEC="nsec1..."        # alternative
```

### Relay Selection

| Relay | Notes |
|-------|-------|
| `wss://relay.damus.io` | Popular, reliable |
| `wss://relay.nostr.band` | Good search/discovery |
| `wss://nos.lol` | Community relay |
| `wss://purplepag.es` | Profile/contact list relay |

**Self-hosted relay** options: `strfry` (C++, high-performance), `nostr-rs-relay` (Rust), `nostream` (TypeScript).

### Event Subscription

```typescript
import { SimplePool } from "nostr-tools"

const pool = new SimplePool()
const relays = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.nostr.band"]

const sub = pool.subscribeMany(relays, [{
  kinds: [4],                                   // NIP-04 encrypted DMs
  "#p": [botPublicKey],                         // addressed to bot
  since: Math.floor(Date.now() / 1000),         // only new events
}], {
  onevent(event) { /* decrypt and process */ },
  oneose() { console.log("Listening for new events") },
})
```

## Bot API Integration

### NIP-01: Basic Event Structure

```typescript
interface NostrEvent {
  id: string         // sha256 of serialized event
  pubkey: string     // hex public key of creator
  created_at: number // Unix timestamp
  kind: number       // event type
  tags: string[][]   // metadata tags
  content: string    // event content (may be encrypted)
  sig: string        // secp256k1 schnorr signature
}
```

### Event Kinds

| Kind | NIP | Description |
|------|-----|-------------|
| 0 | NIP-01 | User metadata (profile) |
| 1 | NIP-01 | Text note (public post) |
| 3 | NIP-02 | Contact list / follow list |
| 4 | NIP-04 | Encrypted direct message |
| 5 | NIP-09 | Event deletion request |
| 7 | NIP-25 | Reaction (like, emoji) |
| 1059 | NIP-17 | Gift-wrapped event (metadata-hiding DM) |
| 10002 | NIP-65 | Relay list metadata |
| 30023 | NIP-23 | Long-form content |

### NIP-04: Encrypted Direct Messages

```typescript
import { nip04, finalizeEvent } from "nostr-tools"

// Decrypt incoming DM
async function decryptDM(event: NostrEvent, botSk: Uint8Array): Promise<string> {
  return nip04.decrypt(botSk, event.pubkey, event.content)
}

// Send encrypted DM
async function sendDM(recipientPk: string, msg: string, botSk: Uint8Array) {
  const ciphertext = await nip04.encrypt(botSk, recipientPk, msg)
  return finalizeEvent({
    kind: 4,
    created_at: Math.floor(Date.now() / 1000),
    tags: [["p", recipientPk]],
    content: ciphertext,
  }, botSk)
}
```

### NIP-44: Versioned Encryption (Recommended)

NIP-44 improves on NIP-04 with versioned encryption, padding (hides message length), and XChaCha20:

```typescript
import { nip44 } from "nostr-tools"

const convKey = nip44.v2.utils.getConversationKey(sk, recipientPubkey)
const ciphertext = nip44.v2.encrypt(message, convKey)
const plaintext = nip44.v2.decrypt(ciphertext, convKey)
```

### NIP-17: Gift-Wrapped DMs (Metadata-Hiding)

NIP-17 wraps DMs in multiple layers to hide metadata from relays. Adoption is still limited but represents the future of Nostr private messaging:

- **Seal**: Inner event encrypted to recipient, contains actual DM
- **Gift wrap**: Outer event with randomized pubkey and timestamp
- Relays see only the gift wrap — cannot determine sender, recipient, or timing

### Basic Bot Example

```typescript
import { SimplePool, finalizeEvent, getPublicKey, nip04, nip19 } from "nostr-tools"

const RELAYS = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.nostr.band"]

// Load bot key from secure storage
const botNsec = process.env.NOSTR_BOT_NSEC
if (!botNsec) throw new Error("NOSTR_BOT_NSEC not set")
const { data: botSecretKey } = nip19.decode(botNsec) as { data: Uint8Array }
const botPublicKey = getPublicKey(botSecretKey)

// Pubkey allowlist (hex pubkeys of authorized users)
const ALLOWED_PUBKEYS = new Set<string>([
  // "hex_pubkey_1", "hex_pubkey_2",
])

const pool = new SimplePool()

pool.subscribeMany(RELAYS, [{
  kinds: [4], "#p": [botPublicKey], since: Math.floor(Date.now() / 1000),
}], {
  async onevent(event) {
    if (ALLOWED_PUBKEYS.size > 0 && !ALLOWED_PUBKEYS.has(event.pubkey)) return

    try {
      const plaintext = await nip04.decrypt(botSecretKey, event.pubkey, event.content)
      const response = await handleCommand(plaintext)
      const ciphertext = await nip04.encrypt(botSecretKey, event.pubkey, response)
      const reply = finalizeEvent({
        kind: 4, created_at: Math.floor(Date.now() / 1000),
        tags: [["p", event.pubkey]], content: ciphertext,
      }, botSecretKey)
      await Promise.any(pool.publish(RELAYS, reply))
    } catch (err) {
      console.error("Error processing DM:", err)
    }
  },
  oneose() { console.log("Listening for DMs...") },
})

async function handleCommand(text: string): Promise<string> {
  const cmd = text.trim().toLowerCase()
  if (cmd === "/help") return "/help — This message\n/status — System status\n/ask <q> — Ask AI"
  if (cmd === "/status") return "Bot online. Connected to " + RELAYS.length + " relays."
  if (cmd.startsWith("/ask ")) return "Processing: " + text.slice(5).trim()
  return 'Unknown command. Type "/help" for available commands.'
}

process.on("SIGINT", () => { pool.close(RELAYS); process.exit(0) })
```

### Relay Management

```typescript
const pool = new SimplePool()

// Publish to multiple relays
await Promise.any(pool.publish(relays, signedEvent))

// Query events
const events = await pool.querySync(relays, { kinds: [1], authors: [pubkey], limit: 10 })
const event = await pool.get(relays, { ids: [eventId] })

pool.close(relays)
```

### Access Control

Access control is pubkey-based. Maintain an allowlist of authorized hex pubkeys, loaded from config. If the allowlist is empty, the bot is open to all. Check `event.pubkey` against the allowlist before processing any command.

## Security Considerations

### Encryption

NIP-04 DMs use secp256k1 ECDH to derive a shared secret, then AES-256-CBC to encrypt message content. The encrypted content is stored in the event's `content` field. However, the event envelope (sender pubkey, recipient pubkey tag, timestamp, event kind) is **visible to all relays**.

NIP-44 improves on NIP-04 with versioned encryption, message padding (hides exact length), and XChaCha20 instead of AES-256-CBC.

NIP-17 (gift-wrapping) hides metadata by wrapping events in layers — inner seal encrypted to recipient, outer gift wrap with random pubkey and randomized timestamp. Relay sees only the gift wrap.

**Adoption status**: NIP-04 is universally supported. NIP-44 has growing support. NIP-17 is still limited.

### Metadata Exposure

**THIS IS THE KEY WEAKNESS OF NOSTR DMs.**

With NIP-04 (current standard), relay operators can see:

- **WHO** is messaging **WHOM** (sender and recipient pubkeys)
- **WHEN** messages are sent (timestamps)
- That the event **IS** a DM (kind 4)
- They **CANNOT** see message content (encrypted)

Pubkeys are pseudonymous but can be linked to real identities if the user publishes identifying info in their profile (kind 0), links their npub publicly, uses a NIP-05 identifier on a known domain, or reuses pubkeys across contexts.

NIP-17 gift-wrapping addresses this but adoption is limited. Until widely supported, treat Nostr DMs as having **weaker metadata privacy than SimpleX or Signal**.

### Decentralization

No single entity controls the network. Relays are independently operated — anyone can run one. Users choose which relays to use. A relay operator can see all events on their relay but not events on other relays. Censorship requires cooperation of ALL relays a user publishes to.

### No PII Required

Identity is purely keypair-based. No phone number, no email, no username registration, no server account. No SIM-swapping attacks, no email-based recovery attacks, pseudonymous by default. This is a significant privacy advantage.

### Push Notifications

No push notifications in the traditional sense. Clients maintain WebSocket connections or poll periodically. No Google FCM or Apple APNs metadata exposure. Some clients use optional push services with a trust trade-off.

### AI Training Risk

The protocol itself has no AI training risk. Public notes (kind 1) are **public by design** — anyone can read and train on them. Encrypted DMs (kind 4) are not accessible to relays. Individual relay operators set their own data policies.

### Open Source

Protocol specification is fully open ([NIPs repository](https://github.com/nostr-protocol/nips)). All major clients (Damus, Amethyst, Primal, Snort) and relay implementations (strfry, nostr-rs-relay, nostream) are open-source. nostr-tools is MIT licensed. No proprietary components.

### Key Management

- Private key (nsec) security is **critical** — if compromised, attacker can impersonate the user **permanently**
- No key rotation mechanism in the base protocol — a compromised key cannot be revoked
- NIP-46 (Nostr Connect) allows delegated signing without exposing nsec
- Hardware key storage via NIP-46 signers is the gold standard for high-value identities
- **Recommendation**: Generate a dedicated keypair for the bot, separate from any personal identity

### Relay Trust

You must trust relay operators not to censor events or log/correlate metadata. Use multiple relays for redundancy. Self-hosting eliminates relay trust entirely. Paid relays offer better reliability but introduce a payment metadata link.

### Comparison with Other Protocols

| Aspect | Nostr | SimpleX | Signal | Matrix |
|--------|-------|---------|--------|--------|
| PII required | None | None | Phone number | Optional |
| DM content privacy | Encrypted | Encrypted | Encrypted | Encrypted |
| DM metadata privacy | Weak (pubkeys visible) | Strongest (no IDs) | Good (sealed sender) | Moderate |
| Censorship resistance | Strongest | Strong | Moderate | Moderate |
| Key compromise impact | Permanent impersonation | Per-connection | Account takeover | Account takeover |
| Decentralization | Full (relay-based) | Full (no servers needed) | Centralized | Federated |

**Summary**: Nostr is best for censorship resistance and pseudonymous public communication. For private messaging, SimpleX offers stronger metadata privacy. For bot integration where censorship resistance matters more than metadata hiding, Nostr is the superior choice.

## aidevops Integration

### Helper Script Pattern

```bash
#!/usr/bin/env bash
# ~/.aidevops/agents/scripts/nostr-dispatch-helper.sh
set -euo pipefail

nostr_dispatch() {
  local sender_pubkey="$1"
  local command="$2"

  if ! is_authorized "$sender_pubkey"; then
    echo "Unauthorized sender: $sender_pubkey"
    return 1
  fi

  case "$command" in
    /status)  aidevops status; return 0 ;;
    /pulse)   aidevops pulse; return 0 ;;
    /ask\ *)  aidevops research "${command#/ask }"; return 0 ;;
    *)        echo "Unknown command: $command"; return 1 ;;
  esac
}

is_authorized() {
  local pubkey="$1"
  local config_file="${HOME}/.config/aidevops/nostr-bot.json"
  if [[ ! -f "$config_file" ]]; then
    echo "No config found: $config_file"
    return 1
  fi
  if jq -e --arg pk "$pubkey" '.allowed_users[] | select(. == $pk)' "$config_file" > /dev/null 2>&1; then
    return 0
  fi
  return 1
}
```

### Configuration

Config path: `~/.config/aidevops/nostr-bot.json`

```json
{
  "bot_nsec_gopass_path": "aidevops/nostr-bot/nsec",
  "relays": [
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.nostr.band"
  ],
  "allowed_users": [
    "hex_pubkey_of_authorized_user_1",
    "hex_pubkey_of_authorized_user_2"
  ],
  "self_hosted_relay": null,
  "log_level": "info"
}
```

### Entity Resolution

Nostr uses hex pubkeys internally and bech32-encoded npub/nsec for display:

```typescript
import { nip19, nip05 } from "nostr-tools"

const { data: hexPubkey } = nip19.decode("npub1...")  // npub → hex
const npub = nip19.npubEncode(hexPubkey)              // hex → npub

// NIP-05 resolution (user@domain.com → pubkey)
const profile = await nip05.queryProfile("user@domain.com")
// profile.pubkey, profile.relays
```

### Runner Dispatch

The bot dispatches tasks via the standard pattern: receive DM → validate sender pubkey → parse command → dispatch via `nostr-dispatch-helper.sh` → collect result → send encrypted DM response.

## Matterbridge Integration

**NO native Matterbridge support for Nostr.**

Matterbridge does not include a Nostr gateway. Bridging would require a custom gateway implementation.

### Bridging Feasibility

| Aspect | Assessment |
|--------|------------|
| Technical feasibility | Moderate — Nostr's event model maps to messages |
| Effort | High — requires custom Matterbridge gateway plugin |
| Public notes (kind 1) | Straightforward to bridge (plain text) |
| DMs (kind 4) | Complex — requires bot to decrypt/re-encrypt |
| Identity mapping | Difficult — Nostr pubkeys don't map to usernames |
| Direction | Nostr→other is easier; other→Nostr requires signing |

**Alternative**: Bot-level bridging — bot decrypts Nostr DM, re-sends via Matrix/SimpleX, and vice versa. Simpler but less scalable than a proper Matterbridge gateway.

## Limitations

### NIP-04 DM Metadata Visibility

With NIP-04, relay operators can see sender/recipient pubkeys and timestamps for all DMs. Content is encrypted but the social graph is exposed. NIP-17 gift-wrapping addresses this but adoption is limited.

### No Rich Interactive Elements

No protocol-level support for inline buttons, keyboards, interactive forms, menus, typing indicators, or read receipts. Bot interaction is text-command-based only.

### Relay Reliability

Relays are independently operated with varying uptime, no SLA. Free relays may rate-limit or filter. **Mitigation**: Connect to multiple relays; self-host for critical bots.

### No Guaranteed Message Delivery

If all relays are offline or the bot is offline, messages may be lost. No delivery receipts in the base protocol. **Mitigation**: Use `since` filter on reconnect; use relays with good retention policies.

### Key Management Complexity

No key rotation — a compromised nsec is permanently compromised. No account recovery. NIP-46 adds complexity but improves security. **Mitigation**: Dedicated bot keypairs in gopass, rotate by creating new identity.

### Small Ecosystem

Significantly fewer users than mainstream messengers. Developer tooling less mature. Documentation scattered across NIPs. Rapidly evolving protocol.

### No Voice or Video Calls

The protocol does not include voice/video capabilities. Some clients experiment with WebRTC signaling over Nostr events but there is no standardized NIP.

### Client Compatibility

Different clients support different NIP subsets. A NIP-44 DM may not be readable by NIP-04-only clients. Bot should handle both for maximum compatibility. NIP-17 support is very limited.

### Spam

Public relays are susceptible to spam. No built-in protocol-level filtering. Relays implement their own anti-spam (proof of work, payment, allowlists). Bots should implement pubkey allowlisting.

## Related

- `.agents/services/communications/simplex.md` — SimpleX Chat (strongest metadata privacy)
- `.agents/services/communications/matrix-bot.md` — Matrix messaging (federated, mature ecosystem)
- `.agents/services/communications/bitchat.md` — BitChat (Bitcoin-native messaging)
- `.agents/services/communications/xmtp.md` — XMTP (Ethereum-native messaging)
- `.agents/services/communications/matterbridge.md` — Matterbridge (cross-platform bridging)
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/credentials/gopass.md` — Secret management (for nsec storage)
- `.agents/tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- Nostr NIPs: https://github.com/nostr-protocol/nips
- nostr-tools: https://github.com/nbd-wtf/nostr-tools
- Nostr relay list: https://nostr.watch/
- Awesome Nostr: https://github.com/aljazceru/awesome-nostr
