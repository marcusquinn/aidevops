---
description: Urbit — decentralized personal server OS, bot integration via Eyre HTTP API, Ames P2P encrypted networking, Azimuth identity (Ethereum L2), graph-store messaging, maximum sovereignty, and limitations
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

# Urbit Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Decentralized personal server OS — maximum sovereignty, peer-to-peer encrypted
- **License**: MIT (Urbit runtime), various open-source licenses for components
- **Bot tool**: Urbit HTTP API (Eyre) — external integration via HTTP/SSE
- **Protocol**: Ames (P2P encrypted networking), Eyre (HTTP API gateway)
- **Encryption**: Ames provides E2E encryption between ships (Curve25519 + AES)
- **Identity**: Urbit ID (Azimuth) — decentralized identity on Ethereum L2
- **Runtime**: https://github.com/urbit/urbit (Vere runtime)
- **Docs**: https://docs.urbit.org/ | https://developers.urbit.org/
- **Azimuth**: https://azimuth.network/

**Key differentiator**: Urbit is not just a messaging app — it is a personal server operating system. Your ship is your computer on the network. You own your identity (an NFT on Ethereum L2), your data, your applications, and your network connections. No company controls the network. No terms of service. No deplatforming. This makes it the maximum sovereignty option — you own everything.

**When to use Urbit over other protocols**:

| Criterion | Urbit | Nostr | SimpleX | Matrix |
|-----------|-------|-------|---------|--------|
| Identity | Azimuth (NFT, owned) | Keypair (nsec/npub) | None (pairwise) | `@user:server` |
| Sovereignty | Maximum (own server) | High (relay-dependent) | High (no servers) | Moderate (federated) |
| Metadata privacy | Strong (P2P, no relays) | Weak (relay sees pubkeys) | Strongest (no IDs) | Moderate |
| PII required | None (NFT identity) | None | None | Optional but common |
| Bot ecosystem | Minimal (HTTP API) | Growing (nostr-tools) | Growing (WebSocket API) | Mature (SDK, bridges) |
| Persistence | Full (ship stores all data) | Relay-dependent | None (ephemeral) | Full history |
| Best for | Maximum sovereignty, personal server | Censorship resistance | Maximum privacy | Team collaboration |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────────┐     ┌──────────────────────────┐
│ Urbit Ship A              │     │ Urbit Ship B              │
│ (your personal server)    │     │ (another user's ship)     │
│                           │     │                           │
│ ├─ Arvo (OS kernel)       │     │ ├─ Arvo (OS kernel)       │
│ ├─ Ames (P2P networking)  │◄───►│ ├─ Ames (P2P networking)  │
│ ├─ Eyre (HTTP server)     │     │ ├─ Eyre (HTTP server)     │
│ ├─ Graph Store (messages) │     │ ├─ Graph Store (messages) │
│ ├─ Groups (social app)    │     │ ├─ Groups (social app)    │
│ └─ Landscape (web UI)     │     │ └─ Landscape (web UI)     │
└──────────┬───────────────┘     └──────────────────────────┘
           │
           │ Eyre HTTP API (localhost)
           │ Authentication via +code
           │
┌──────────▼───────────────┐
│ Bot Process               │
│ (TypeScript/Bun)          │
│                           │
│ ├─ HTTP client (auth)     │
│ ├─ SSE subscription       │
│ │   (real-time events)    │
│ ├─ Poke handler           │
│ │   (send actions)        │
│ ├─ Scry reader            │
│ │   (read state)          │
│ ├─ Command router         │
│ └─ aidevops dispatch      │
└───────────────────────────┘
```

**Message flow**: Ship A sends message via Ames (E2E encrypted, P2P) → Ship B receives and stores in graph-store → External bot connects to Ship B's Eyre HTTP API → subscribes to graph-store updates via SSE → processes incoming messages → pokes graph-store to send responses → Ames delivers response to Ship A.

**Identity tiers**:

| Tier | Count | Cost | Purpose |
|------|-------|------|---------|
| Galaxy (~gal) | 256 | Very expensive | Infrastructure, governance |
| Star (~star) | ~65,536 | Moderate | Issue planets, relay |
| Planet (~planet) | ~4 billion | $10-50 USD | Personal identity |
| Comet (~comet) | 2^128 | Free | Temporary, limited |

## Installation

### Urbit Runtime

```bash
# Linux
curl -L https://urbit.org/install/linux-x86_64/latest -o urbit
chmod +x urbit
sudo mv urbit /usr/local/bin/

# macOS
curl -L https://urbit.org/install/mac/latest -o urbit
chmod +x urbit
sudo mv urbit /usr/local/bin/

# Verify
urbit --version
```

### Obtaining an Urbit ID (Planet)

Urbit identity is an NFT on Ethereum L2 (Azimuth). To get a planet:

1. **Purchase**: Buy from a star operator or marketplace (e.g., azimuth.network, urbitex.io, ~tirrel planet sales)
2. **Receive**: Some communities distribute free planets
3. **Cost**: Typically $10-50 USD
4. **Wallet**: You receive a master ticket (BIP39 mnemonic) — this controls the identity

**Alternative**: Boot a comet (free, no purchase needed) for testing. Comets have long names and limited reputation but full functionality.

### Booting a Ship

```bash
# Boot a planet (first time — requires planet name and key file)
urbit -w sampel-palnet -k /path/to/keyfile.key

# Boot a comet (free, no identity purchase needed)
urbit -c mycomet

# Resume an existing ship
urbit mycomet/

# Boot with specific Ames port
urbit -p 34567 mycomet/
```

**First boot** takes several minutes (OTA download of latest Arvo OS). Subsequent boots are fast.

### Eyre HTTP API Configuration

Eyre (the HTTP server vane) runs by default on port 8080 (or next available). To configure:

```hoon
:: In dojo (Urbit's command line):
:: Set HTTP port
|pass [%e %set-host-port ~ `8080]

:: Get authentication code (needed for API access)
+code
:: Returns something like: lidlut-tabwed-pillex-ridlup
```

The `+code` output is the authentication password for the HTTP API. Store it securely.

### Networking (Ames)

Ames is the P2P networking protocol. Ships communicate directly when possible, falling back to galaxy/star infrastructure for NAT traversal.

```bash
# Boot with specific Ames port (useful for port forwarding)
urbit -p 34567 mycomet/

# Port forwarding for direct P2P connections (recommended)
# Forward UDP port 34567 on your router to the ship's host
```

**NAT traversal**: If direct P2P is not possible, Ames routes through the ship's sponsor (star) or a galaxy. This adds latency but works without port forwarding.

## Bot API Integration

### Authentication

All Eyre API requests require authentication via a session cookie:

```typescript
// Authenticate and get session cookie
async function authenticate(shipUrl: string, code: string): Promise<string> {
  const response = await fetch(`${shipUrl}/~/login`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `password=${code}`,
    redirect: "manual",
  })

  const setCookie = response.headers.get("set-cookie")
  if (!setCookie) throw new Error("Authentication failed — no cookie returned")
  const match = setCookie.match(/urbauth-[^=]+=([^;]+)/)
  if (!match) throw new Error("Authentication failed — invalid cookie format")
  return setCookie.split(";")[0] // Return full cookie header value
}
```

### SSE Subscriptions (Real-Time Events)

Subscribe to ship events via Server-Sent Events:

```typescript
// Subscribe to graph-store updates via SSE
function subscribeToUpdates(
  shipUrl: string,
  cookie: string,
  onEvent: (data: unknown) => void
): EventSource {
  // First, open an SSE channel
  const channelId = `bot-${Date.now()}`
  const sseUrl = `${shipUrl}/~/channel/${channelId}`

  // Subscribe by sending a poke/subscribe action
  fetch(sseUrl, {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      Cookie: cookie,
    },
    body: JSON.stringify([
      {
        id: 1,
        action: "subscribe",
        ship: "sampel-palnet",   // your ship name (without ~)
        app: "graph-store",
        path: "/updates",
      },
    ]),
  })

  // Then listen for events
  const es = new EventSource(sseUrl, {
    // Note: EventSource doesn't natively support cookies
    // Use a library like eventsource that supports headers
  })

  es.onmessage = (event) => {
    const data = JSON.parse(event.data)
    // ACK the event to prevent replay
    fetch(sseUrl, {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        Cookie: cookie,
      },
      body: JSON.stringify([
        { id: data.id + 1, action: "ack", "event-id": data.id },
      ]),
    })
    onEvent(data)
  }

  return es
}
```

### Pokes (Sending Actions)

Poke an app to trigger an action (e.g., send a message):

```typescript
// Poke graph-store to send a message
async function sendMessage(
  shipUrl: string,
  cookie: string,
  channelId: string,
  recipientShip: string,
  message: string
): Promise<void> {
  const now = Date.now()
  const index = `/${now}`

  await fetch(`${shipUrl}/~/channel/${channelId}`, {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      Cookie: cookie,
    },
    body: JSON.stringify([
      {
        id: now,
        action: "poke",
        ship: "sampel-palnet",   // your ship name
        app: "graph-store",
        mark: "graph-update-3",
        json: {
          "add-nodes": {
            resource: {
              ship: "sampel-palnet",
              name: `dm-inbox`,
            },
            nodes: {
              [index]: {
                post: {
                  author: "sampel-palnet",
                  index,
                  "time-sent": now,
                  contents: [{ text: message }],
                  hash: null,
                  signatures: [],
                },
                children: null,
              },
            },
          },
        },
      },
    ]),
  })
}
```

### Scry Endpoints (Reading State)

Scry is a read-only interface for querying ship state:

```typescript
// Read ship state via scry
async function scry(
  shipUrl: string,
  cookie: string,
  app: string,
  path: string
): Promise<unknown> {
  const response = await fetch(
    `${shipUrl}/~/scry/${app}${path}.json`,
    { headers: { Cookie: cookie } }
  )
  if (!response.ok) throw new Error(`Scry failed: ${response.status}`)
  return response.json()
}

// Examples:
// Get all DM conversations
const dms = await scry(url, cookie, "graph-store", "/keys")

// Get messages from a specific graph
const messages = await scry(url, cookie, "graph-store",
  "/graph/~sampel-palnet/dm-inbox/node/subset/kith/lone/newest/count/20")

// Get contact list
const contacts = await scry(url, cookie, "contact-store", "/all")
```

### Thread Execution

Threads allow complex multi-step operations:

```typescript
// Execute a thread (spider)
async function runThread(
  shipUrl: string,
  cookie: string,
  desk: string,
  threadName: string,
  inputMark: string,
  outputMark: string,
  body: unknown
): Promise<unknown> {
  const response = await fetch(
    `${shipUrl}/spider/${desk}/${inputMark}/${threadName}/${outputMark}.json`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Cookie: cookie,
      },
      body: JSON.stringify(body),
    }
  )
  return response.json()
}
```

### Access Control

Access control is ship-based. Maintain an allowlist of ship names (e.g., `~zod`, `~sampel-palnet`) that are authorized to interact with the bot. Check the author field of incoming messages against this allowlist.

```typescript
const ALLOWED_SHIPS = new Set<string>([
  // "~sampel-palnet",
  // "~zod",
])

function isAuthorized(ship: string): boolean {
  if (ALLOWED_SHIPS.size === 0) return true // open to all if empty
  return ALLOWED_SHIPS.has(ship)
}
```

### Basic Bot Example

```typescript
import { EventSourcePlus } from "event-source-plus"

const SHIP_URL = "http://localhost:8080"
const SHIP_NAME = "sampel-palnet"
const SHIP_CODE = process.env.URBIT_SHIP_CODE
if (!SHIP_CODE) throw new Error("URBIT_SHIP_CODE not set")

// Authenticate
const loginResp = await fetch(`${SHIP_URL}/~/login`, {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: `password=${SHIP_CODE}`,
  redirect: "manual",
})
const cookie = loginResp.headers.get("set-cookie")?.split(";")[0]
if (!cookie) throw new Error("Login failed")

const channelId = `bot-${Date.now()}`
const channelUrl = `${SHIP_URL}/~/channel/${channelId}`

// Subscribe to graph-store updates
await fetch(channelUrl, {
  method: "PUT",
  headers: { "Content-Type": "application/json", Cookie: cookie },
  body: JSON.stringify([{
    id: 1,
    action: "subscribe",
    ship: SHIP_NAME,
    app: "graph-store",
    path: "/updates",
  }]),
})

// Listen for events via SSE
const sse = new EventSourcePlus(channelUrl, {
  headers: { Cookie: cookie },
})

sse.listen({
  onMessage(event) {
    try {
      const data = JSON.parse(event.data)

      // ACK the event
      fetch(channelUrl, {
        method: "PUT",
        headers: { "Content-Type": "application/json", Cookie: cookie },
        body: JSON.stringify([{
          id: Date.now(),
          action: "ack",
          "event-id": data.id,
        }]),
      })

      // Process graph-store updates
      if (data.json?.["add-nodes"]) {
        const nodes = data.json["add-nodes"].nodes
        for (const [index, node] of Object.entries(nodes)) {
          // Runtime type guard — validate structure before accessing properties
          const nodeObj = node as Record<string, unknown>
          if (!nodeObj?.post || typeof nodeObj.post !== "object") continue
          const rawPost = nodeObj.post as Record<string, unknown>
          if (typeof rawPost.author !== "string" || !Array.isArray(rawPost.contents)) continue
          const author = rawPost.author
          const contents = rawPost.contents as Array<Record<string, unknown>>
          if (author !== SHIP_NAME) {
            const textContent = contents
              .filter((c) => c != null && typeof c === "object" && typeof c.text === "string")
              .map((c) => c.text as string)
              .join(" ")
            console.log(`Message from ~${author}: ${textContent}`)
            // Handle command and send response...
          }
        }
      }
    } catch (err) {
      console.error("Error processing event:", err)
    }
  },
})

console.log(`Bot listening on ${SHIP_URL} as ~${SHIP_NAME}`)
```

## Security Considerations

### Decentralization

**FULLY decentralized.** Each user runs their own server (ship). No central servers, no company controlling the network. Your ship is YOUR computer. The Urbit Foundation steers development but has no control over running ships. No single entity can censor, deplatform, or surveil users.

### Encryption

Ames protocol provides E2E encryption between ships using Curve25519 key exchange and AES symmetric encryption. All inter-ship communication is encrypted by default — there is no unencrypted mode. This is transport-level and content-level encryption combined in one protocol.

### Metadata Privacy

No central entity collects metadata. Your ship knows who you communicate with, but no third party does. Network topology is peer-to-peer — when direct connections are possible, no intermediary sees any metadata at all.

**Caveat**: When NAT traversal is required, galaxy/star infrastructure routes initial connections. These nodes could theoretically log connection metadata (which ships are communicating) but cannot read content. Self-hosting a star eliminates this concern entirely.

### Identity

Urbit ID (Azimuth) is decentralized identity on Ethereum L2. Identity is an NFT — you own it cryptographically. No phone number, no email, no central authority can revoke it.

| Tier | Count | Acquisition | Reputation |
|------|-------|-------------|------------|
| Galaxy | 256 | Purchased (very expensive) | Highest — infrastructure nodes |
| Star | ~65,536 | Purchased (moderate) | High — issues planets |
| Planet | ~4 billion | Purchased ($10-50) | Standard — personal identity |
| Comet | 2^128 | Free (self-generated) | Lowest — temporary, often filtered |

### Push Notifications

No push notifications. Ships are always-on servers — they receive messages directly via Ames. No Google FCM or Apple APNs dependency. No metadata leakage to push notification providers.

### AI Training Risk

No AI training risk from the protocol or network. Your data lives on your ship. No external company has access to your messages, contacts, or application data. There is no cloud service harvesting user data.

### Open Source

Fully open-source:

| Component | License | Repository |
|-----------|---------|------------|
| Vere (runtime) | MIT | https://github.com/urbit/urbit |
| Arvo (OS) | MIT | https://github.com/urbit/urbit |
| Azimuth (identity) | MIT | https://github.com/urbit/azimuth |
| Landscape (web UI) | MIT | https://github.com/tloncorp/landscape |
| Groups (social app) | MIT | https://github.com/tloncorp/tlon-apps |

Active development community. All core applications are open-source and auditable.

### Sovereignty

**Maximum digital sovereignty.** You own your identity, your data, your server, your network connections. No terms of service, no content moderation by a platform, no deplatforming risk. Your ship is a general-purpose computer that you control completely.

This exceeds even Nostr's sovereignty model — Nostr users depend on relay operators for message delivery and persistence. Urbit ships store their own data and communicate directly.

### Key Management

- **Master ticket**: BIP39 mnemonic that controls the Urbit ID — this is the root credential
- **Management proxy**: Can configure networking keys, set spawn proxy, etc.
- **Networking keys**: Used for Ames encryption — can be rotated (breach)
- **Breach**: Resetting networking keys. Disrupts all existing connections — contacts must reconnect. Use only when keys are compromised.
- **Hardware wallet**: Azimuth supports hardware wallet storage for master ticket (Trezor, Ledger)
- **Recommendation**: Store master ticket in hardware wallet or gopass. Use management proxy for day-to-day operations.

```bash
# Store Urbit credentials securely
gopass insert aidevops/urbit-bot/ship-code    # +code for Eyre API
gopass insert aidevops/urbit-bot/master-ticket # Master ticket (CRITICAL)
```

### Practical Concerns

- Galaxy/star infrastructure routes Ames connections for NAT traversal — these nodes could log connection metadata (which ships communicate) but not content
- Self-hosting a star mitigates this entirely
- Ship must be running 24/7 to receive messages — requires always-on infrastructure
- Breach (key reset) is disruptive — all peers must re-establish connections

### Comparison with Other Protocols

| Aspect | Urbit | Nostr | SimpleX | Signal | Matrix |
|--------|-------|-------|---------|--------|--------|
| PII required | None (NFT identity) | None | None | Phone number | Optional |
| Sovereignty | Maximum (own server) | High | High | Low (central) | Moderate |
| DM content privacy | Encrypted (Ames) | Encrypted (NIP-04) | Encrypted (double ratchet) | Encrypted | Encrypted |
| Metadata privacy | Strong (P2P) | Weak (relay sees pubkeys) | Strongest (no IDs) | Good (sealed sender) | Moderate |
| Censorship resistance | Maximum (no deps) | Strong (multi-relay) | Strong | Moderate | Moderate |
| Data ownership | You own everything | Relay-dependent | Ephemeral | Company holds | Server holds |
| Decentralization | Full (P2P) | Full (relay-based) | Full (no servers) | Centralized | Federated |

**Summary**: Maximum sovereignty and privacy — you own everything. More sovereign than even Nostr (which depends on relay operators). The trade-off is complexity: running a personal server requires technical skill and always-on infrastructure. Best for users who prioritize sovereignty above convenience.

## aidevops Integration

### Helper Script Pattern

```bash
#!/usr/bin/env bash
# ~/.aidevops/agents/scripts/urbit-dispatch-helper.sh
set -euo pipefail

urbit_dispatch() {
  local sender_ship="$1"
  local command="$2"

  if ! is_authorized "$sender_ship"; then
    echo "Unauthorized ship: $sender_ship"
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
  local ship="$1"
  local config_file="${HOME}/.config/aidevops/urbit-bot.json"
  if [[ ! -f "$config_file" ]]; then
    echo "No config found: $config_file"
    return 1
  fi
  if jq -e --arg s "$ship" '.allowed_ships[] | select(. == $s)' "$config_file" > /dev/null 2>&1; then
    return 0
  fi
  return 1
}
```

### Configuration

Config path: `~/.config/aidevops/urbit-bot.json`

```json
{
  "ship_name": "sampel-palnet",
  "ship_url": "http://localhost:8080",
  "ship_code_gopass_path": "aidevops/urbit-bot/ship-code",
  "allowed_ships": [
    "~zod",
    "~sampel-palnet"
  ],
  "log_level": "info"
}
```

### Entity Resolution

Urbit uses ship names (phonemic base — pronounceable syllable pairs):

| Format | Example | Usage |
|--------|---------|-------|
| Planet | `~sampel-palnet` | Standard identity |
| Star | `~sampel` | Infrastructure |
| Galaxy | `~zod` | Top-level infrastructure |
| Comet | `~doznec-marzod-...` (long) | Temporary identity |

Ship names are resolved via Ames networking. No external DNS or registry lookup needed — the Azimuth PKI on Ethereum provides the mapping from ship name to networking keys.

### Runner Dispatch

The bot dispatches tasks via the standard pattern: receive message via SSE subscription → validate sender ship name → parse command → dispatch via `urbit-dispatch-helper.sh` → collect result → poke graph-store to send response.

## Matterbridge Integration

**NO native Matterbridge support for Urbit.**

Matterbridge does not include an Urbit gateway. There is no community-maintained bridge.

### Bridging Feasibility

| Aspect | Assessment |
|--------|------------|
| Technical feasibility | Moderate — Eyre HTTP API can be used as integration point |
| Effort | High — requires custom Matterbridge gateway plugin |
| Messages (graph-store) | Possible via SSE subscription + poke |
| DMs | Complex — requires bot ship as relay |
| Identity mapping | Difficult — ship names don't map to usernames on other platforms |
| Direction | Urbit→other via SSE events; other→Urbit via pokes |
| Complexity | Higher than most — Urbit's data model (graph-store) is unique |

**Alternative**: Bot-level bridging — bot subscribes to Urbit graph-store via SSE, re-sends messages to Matrix/SimpleX, and vice versa. Simpler than a Matterbridge gateway but less scalable.

## Limitations

### Steep Learning Curve

Urbit has its own programming language (Hoon), virtual machine (Nock), operating system (Arvo), and networking protocol (Ames). Understanding the system requires learning fundamentally different computing concepts. The documentation assumes familiarity with functional programming.

### Niche Ecosystem

Small user base compared to mainstream messaging platforms. Limited third-party tooling. Community is technically sophisticated but small. Finding developers with Urbit experience is difficult.

### Requires Always-On Server

Your ship must be running 24/7 to receive messages and stay synchronized with the network. This requires always-on infrastructure — a VPS, dedicated server, or always-on home machine. Hosting providers (e.g., Tlon, Red Horizon, Escape Pod) offer managed hosting.

### Urbit ID Cost

Planets (the standard identity tier) cost money — typically $10-50 USD as an NFT purchase. This is a barrier to entry compared to free identity systems. Comets (free) work for testing but have long names and may be filtered by some ships.

### Limited Bot Tooling

No official bot SDK. The Eyre HTTP API is the only external integration point. Bot developers must work with raw HTTP requests, SSE streams, and Urbit's unique data structures (graph-store marks, nouns). No equivalent to Telegram's Bot API or Discord's SDK.

### HTTP API as Only External Interface

Eyre (HTTP server) is the sole integration point for external processes. There is no WebSocket API, no gRPC, no message queue interface. All bot communication must go through HTTP requests and SSE subscriptions.

### Performance

Nock VM (Urbit's execution environment) has overhead compared to native code. Operations that would be instant on a traditional server may take noticeable time on Urbit. This is improving with each runtime release but remains a factor.

### Breaking Changes (Kelvin Versioning)

Urbit uses kelvin versioning — version numbers count DOWN toward zero (stability). This means the system is still evolving and breaking changes can occur between versions. OTA updates are automatic — ships update themselves, which can break bot integrations.

### No Mobile App with Push Notifications

No native mobile app with push notifications. The Tlon app exists but relies on the ship being accessible — there is no push notification infrastructure equivalent to Apple APNs or Google FCM. Users must keep the app connected or check manually.

### NAT Traversal Dependency

Direct P2P connections require proper port forwarding. Without it, Ames routes through galaxy/star infrastructure, adding latency and introducing a metadata exposure point (the relay node sees which ships are communicating).

### No Voice or Video Calls

No protocol-level support for voice or video calls. Some experimental integrations exist but nothing standardized. The focus is on text-based communication and application hosting.

## Related

- `.agents/services/communications/nostr.md` — Nostr (decentralized, relay-based, censorship-resistant)
- `.agents/services/communications/simplex.md` — SimpleX Chat (strongest metadata privacy)
- `.agents/services/communications/matrix-bot.md` — Matrix messaging (federated, mature ecosystem)
- `.agents/services/communications/bitchat.md` — BitChat (Bitcoin-native messaging)
- `.agents/services/communications/xmtp.md` — XMTP (Ethereum-native messaging)
- `.agents/services/communications/discord.md` — Discord bot integration (community, slash commands)
- `.agents/services/communications/msteams.md` — Microsoft Teams bot integration (enterprise, Azure Bot Framework)
- `.agents/services/communications/matterbridge.md` — Matterbridge (cross-platform bridging)
- `.agents/tools/security/opsec.md` — Operational security guidance
- `.agents/tools/credentials/gopass.md` — Secret management (for ship code storage)
- `.agents/tools/ai-assistants/headless-dispatch.md` — Headless AI dispatch patterns
- Urbit Docs: https://docs.urbit.org/
- Urbit Developers: https://developers.urbit.org/
- Azimuth (Identity): https://azimuth.network/
- Urbit GitHub: https://github.com/urbit/urbit
- Tlon (primary developer): https://tlon.io/
