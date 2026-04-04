---
description: Urbit — decentralized personal server OS, bot integration via Eyre HTTP API, Ames P2P encrypted networking, Azimuth identity (Ethereum L2), graph-store messaging
mode: subagent
tools: { read: true, write: false, edit: false, bash: true, glob: false, grep: false, webfetch: false, task: false }
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Urbit Bot Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Decentralized personal server OS — maximum sovereignty, P2P encrypted
- **Bot tool**: Urbit HTTP API (Eyre) — external integration via HTTP/SSE
- **Protocol**: Ames (P2P encrypted), Eyre (HTTP gateway)
- **Encryption**: Ames E2E (Curve25519 + AES) — always on
- **Identity**: Urbit ID (Azimuth) — NFT on Ethereum L2
- **Docs**: https://docs.urbit.org/ | https://developers.urbit.org/

**When to use**: Maximum sovereignty — you own identity, data, server, network. Trade-off: complexity, always-on server, niche ecosystem.

| Criterion | Urbit | Nostr | SimpleX | Matrix |
|-----------|-------|-------|---------|--------|
| Identity | Azimuth (NFT) | Keypair | None | `@user:server` |
| Sovereignty | Maximum | High | High | Moderate |
| Metadata privacy | Strong (P2P) | Weak | Strongest | Moderate |
| Bot ecosystem | Minimal | Growing | Growing | Mature |

<!-- AI-CONTEXT-END -->

## Identity Tiers

| Tier | Count | Cost | Purpose |
|------|-------|------|---------|
| Galaxy (~gal) | 256 | Very expensive | Infrastructure, governance |
| Star (~star) | ~65K | Moderate | Issue planets, relay |
| Planet (~planet) | ~4B | $10-50 | Personal identity |
| Comet (~comet) | 2^128 | Free | Temporary, limited |

## Installation

```bash
curl -L https://urbit.org/install/mac/latest -o urbit && chmod +x urbit && sudo mv urbit /usr/local/bin/
urbit -w sampel-palnet -k /path/to/keyfile.key  # Boot planet (first time)
urbit -c mycomet                                 # Boot comet (free, testing)
urbit mycomet/                                   # Resume
```

Get Eyre auth code in dojo: `+code` → e.g. `lidlut-tabwed-pillex-ridlup`

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
const channelId = `bot-${Date.now()}`, channelUrl = `${SHIP_URL}/~/channel/${channelId}`
await fetch(channelUrl, {
  method: "PUT", headers: { "Content-Type": "application/json", Cookie: cookie },
  body: JSON.stringify([{ id: 1, action: "subscribe", ship: SHIP_NAME, app: "graph-store", path: "/updates" }]),
})
import { EventSourcePlus } from "event-source-plus"
const sse = new EventSourcePlus(channelUrl, { headers: { Cookie: cookie } })
sse.listen({
  onMessage(event) {
    const data = JSON.parse(event.data)
    fetch(channelUrl, { method: "PUT", headers: { "Content-Type": "application/json", Cookie: cookie },
      body: JSON.stringify([{ id: Date.now(), action: "ack", "event-id": data.id }]) })
    const nodes = data.json?.["add-nodes"]?.nodes ?? {}
    for (const node of Object.values(nodes) as any[]) {
      const author = node?.post?.author
      const text = (node?.post?.contents ?? []).filter((c: any) => c.text).map((c: any) => c.text).join(" ")
      if (author && author !== SHIP_NAME) console.log(`~${author}: ${text}`)
    }
  },
})
```

### Scry (Read State) + Access Control

```typescript
const result = await fetch(`${SHIP_URL}/~/scry/${app}${path}.json`, { headers: { Cookie: cookie } })
// app="graph-store" path="/keys" | "/graph/~sampel-palnet/dm-inbox/node/subset/kith/lone/newest/count/20"
const ALLOWED_SHIPS = new Set(["~sampel-palnet"])
const isAuthorized = (ship: string) => ALLOWED_SHIPS.size === 0 || ALLOWED_SHIPS.has(ship)
```

## aidevops Integration

Config: `~/.config/aidevops/urbit-bot.json`

```json
{ "ship_name": "sampel-palnet", "ship_url": "http://localhost:8080",
  "ship_code_gopass_path": "aidevops/urbit-bot/ship-code", "allowed_ships": ["~zod"] }
```

Dispatch: SSE subscription → validate sender → parse command → `urbit-dispatch-helper.sh` → poke response.

```bash
gopass insert aidevops/urbit-bot/ship-code     # +code for Eyre API
gopass insert aidevops/urbit-bot/master-ticket # Master ticket (CRITICAL — controls Azimuth NFT)
```

## Matterbridge

No native support. Custom gateway plugin required (high effort). Alternative: bot-level bridging via SSE + poke.

## Limitations

- **Always-on server** — ship must run 24/7; use VPS or managed hosting (Tlon, Red Horizon)
- **Steep learning curve** — Hoon, Nock VM, Arvo OS, Ames protocol
- **Niche ecosystem** — small user base, no official bot SDK, raw HTTP/SSE only
- **Planet cost** — $10-50 NFT; comets free but long names, may be filtered
- **NAT traversal** — without port forwarding, routes through galaxy/star (latency, metadata)
- **Kelvin versioning** — versions count down; OTA updates can break integrations
- **No voice/video** — text only | **Breach** — key reset requires all peers to reconnect

## Related

- `nostr.md`, `simplex.md`, `matrix-bot.md`, `matterbridge.md` — alternative protocols
- `tools/credentials/gopass.md` — secret management
- https://azimuth.network/ — Urbit ID registry
