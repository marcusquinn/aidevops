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
- **Bot tool**: Urbit HTTP API (Eyre) — external integration via HTTP/SSE
- **Protocol**: Ames (P2P encrypted networking), Eyre (HTTP API gateway)
- **Encryption**: Ames E2E between ships (Curve25519 + AES) — always on
- **Identity**: Urbit ID (Azimuth) — NFT on Ethereum L2
- **Runtime**: https://github.com/urbit/urbit
- **Docs**: https://docs.urbit.org/ | https://developers.urbit.org/

**When to use**: Maximum sovereignty — you own identity, data, server, network. No company controls the network. Trade-off: complexity, always-on server required, niche ecosystem.

| Criterion | Urbit | Nostr | SimpleX | Matrix |
|-----------|-------|-------|---------|--------|
| Identity | Azimuth (NFT, owned) | Keypair | None (pairwise) | `@user:server` |
| Sovereignty | Maximum (own server) | High | High | Moderate |
| Metadata privacy | Strong (P2P) | Weak (relay sees pubkeys) | Strongest | Moderate |
| Bot ecosystem | Minimal (HTTP API) | Growing | Growing | Mature |

<!-- AI-CONTEXT-END -->

## Identity Tiers

| Tier | Count | Cost | Purpose |
|------|-------|------|---------|
| Galaxy (~gal) | 256 | Very expensive | Infrastructure, governance |
| Star (~star) | ~65,536 | Moderate | Issue planets, relay |
| Planet (~planet) | ~4 billion | $10-50 USD | Personal identity |
| Comet (~comet) | 2^128 | Free | Temporary, limited |

## Installation

```bash
# macOS
curl -L https://urbit.org/install/mac/latest -o urbit && chmod +x urbit && sudo mv urbit /usr/local/bin/

# Boot a planet (first time)
urbit -w sampel-palnet -k /path/to/keyfile.key

# Boot a comet (free, for testing)
urbit -c mycomet

# Resume
urbit mycomet/
```

Get the Eyre auth code in dojo: `+code` → returns e.g. `lidlut-tabwed-pillex-ridlup`

## Bot API Integration

### Authentication

```typescript
const loginResp = await fetch(`${SHIP_URL}/~/login`, {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: `password=${process.env.URBIT_SHIP_CODE}`,
  redirect: "manual",
})
const cookie = loginResp.headers.get("set-cookie")?.split(";")[0]
```

### Subscribe + Send (SSE + Poke)

```typescript
const channelId = `bot-${Date.now()}`
const channelUrl = `${SHIP_URL}/~/channel/${channelId}`

// Subscribe to graph-store updates
await fetch(channelUrl, {
  method: "PUT",
  headers: { "Content-Type": "application/json", Cookie: cookie },
  body: JSON.stringify([{ id: 1, action: "subscribe", ship: SHIP_NAME, app: "graph-store", path: "/updates" }]),
})

// Listen via SSE (use event-source-plus for header support)
import { EventSourcePlus } from "event-source-plus"
const sse = new EventSourcePlus(channelUrl, { headers: { Cookie: cookie } })
sse.listen({
  onMessage(event) {
    const data = JSON.parse(event.data)
    // ACK
    fetch(channelUrl, {
      method: "PUT",
      headers: { "Content-Type": "application/json", Cookie: cookie },
      body: JSON.stringify([{ id: Date.now(), action: "ack", "event-id": data.id }]),
    })
    // Process add-nodes events for incoming messages
    const nodes = data.json?.["add-nodes"]?.nodes ?? {}
    for (const node of Object.values(nodes) as any[]) {
      const author = node?.post?.author
      const text = (node?.post?.contents ?? []).filter((c: any) => c.text).map((c: any) => c.text).join(" ")
      if (author && author !== SHIP_NAME) console.log(`~${author}: ${text}`)
    }
  },
})
```

### Scry (Read State)

```typescript
const result = await fetch(`${SHIP_URL}/~/scry/${app}${path}.json`, { headers: { Cookie: cookie } })
// Examples: app="graph-store" path="/keys" | path="/graph/~sampel-palnet/dm-inbox/node/subset/kith/lone/newest/count/20"
```

### Access Control

```typescript
const ALLOWED_SHIPS = new Set(["~sampel-palnet"])
const isAuthorized = (ship: string) => ALLOWED_SHIPS.size === 0 || ALLOWED_SHIPS.has(ship)
```

## aidevops Integration

Config: `~/.config/aidevops/urbit-bot.json`

```json
{
  "ship_name": "sampel-palnet",
  "ship_url": "http://localhost:8080",
  "ship_code_gopass_path": "aidevops/urbit-bot/ship-code",
  "allowed_ships": ["~zod"]
}
```

Dispatch pattern: SSE subscription → validate sender ship → parse command → `urbit-dispatch-helper.sh` → poke graph-store with response.

```bash
# Store credentials
gopass insert aidevops/urbit-bot/ship-code     # +code for Eyre API
gopass insert aidevops/urbit-bot/master-ticket # Master ticket (CRITICAL — controls Azimuth NFT)
```

## Matterbridge

No native Matterbridge support. Custom gateway plugin required (high effort). Alternative: bot-level bridging via SSE + poke.

## Limitations

- **Always-on server required** — ship must run 24/7; use VPS or managed hosting (Tlon, Red Horizon)
- **Steep learning curve** — Hoon language, Nock VM, Arvo OS, Ames protocol
- **Niche ecosystem** — small user base, no official bot SDK, raw HTTP/SSE only
- **Planet cost** — $10-50 USD NFT purchase; comets are free but have long names and may be filtered
- **NAT traversal** — without port forwarding, Ames routes through galaxy/star (adds latency, metadata exposure)
- **Kelvin versioning** — version numbers count down; OTA updates can break bot integrations
- **No voice/video** — text-based only
- **Breach is disruptive** — key reset requires all peers to reconnect

## Related

- `.agents/services/communications/nostr.md` — Nostr (decentralized, relay-based)
- `.agents/services/communications/simplex.md` — SimpleX (strongest metadata privacy)
- `.agents/services/communications/matrix-bot.md` — Matrix (federated, mature ecosystem)
- `.agents/services/communications/matterbridge.md` — Cross-platform bridging
- `.agents/tools/credentials/gopass.md` — Secret management
- Urbit Docs: https://docs.urbit.org/
- Azimuth: https://azimuth.network/
