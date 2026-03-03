---
description: Urbit — personal server OS with peer-to-peer encrypted messaging (Ames protocol), decentralized identity (Urbit ID / Azimuth), Hoon/Nock programming, HTTP API for external integration, maximum sovereignty
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

# Urbit

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Personal server OS with built-in P2P encrypted networking — decentralized identity, deterministic computing, sovereign infrastructure
- **License**: MIT (Vere runtime), MIT (Urbit OS / Arvo kernel)
- **Runtime**: Vere (C-based Nock interpreter) — runs a single "ship" (personal server instance)
- **Language**: Hoon (high-level, compiles to Nock) / Nock (minimal combinator VM)
- **Networking**: Ames protocol — E2E encrypted, peer-to-peer, authenticated by Urbit ID
- **Identity**: Azimuth (Ethereum L1 PKI) — hierarchical address space (~galaxy > ~star > ~planet > ~moon > ~comet)
- **HTTP API**: Eyre (HTTP server vane) — SSE for events, PUT/POST for actions (JSON via `mark` system)
- **Apps**: Groups (chat/forums), Notebook, Landscape (web UI), third-party apps via `desk` distribution
- **Repo**: [github.com/urbit/urbit](https://github.com/urbit/urbit) (runtime) | [github.com/urbit/vere](https://github.com/urbit/vere) (Vere)
- **Docs**: [docs.urbit.org](https://docs.urbit.org/) | [developers.urbit.org](https://developers.urbit.org/)
- **Network explorer**: [network.urbit.org](https://network.urbit.org/)

**Key differentiator**: Urbit is a complete personal server OS, not just a messaging protocol. Each user runs their own deterministic computer ("ship") with a permanent cryptographic identity. All networking is E2E encrypted between ships via the Ames protocol. There are no central servers — your data lives on your ship, and you own your identity as an Ethereum NFT. This provides maximum sovereignty at the cost of requiring your own infrastructure.

**When to use Urbit vs other protocols**:

| Criterion | Urbit | SimpleX | Matrix | XMTP |
|-----------|-------|---------|--------|------|
| Identity model | Urbit ID (Azimuth NFT) | None | `@user:server` | Wallet/DID |
| Encryption | Ames (E2E, per-ship keys) | Double ratchet (X3DH) | Megolm (optional) | MLS + post-quantum |
| Server model | Self-hosted personal server | Stateless relays | Federated servers | Decentralized nodes |
| Programming model | Full OS (Hoon/Nock apps) | Bot WebSocket API | Client-server SDK | Agent SDK |
| Bot/API support | HTTP API (Eyre) + custom agents | WebSocket JSON API | `matrix-bot-sdk` | `@xmtp/agent-sdk` |
| Decentralization | Fully decentralized (each ship is sovereign) | Decentralized relays | Federated | Node operators |
| Best for | Maximum sovereignty, long-term personal computing | Maximum privacy | Team collaboration | Web3/agent messaging |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌─────────────────────────────────────────────────────┐
│ Urbit Ship (~sampel-palnet)                         │
│                                                     │
│ ┌─────────────────────────────────────────────────┐ │
│ │ Arvo (Kernel)                                   │ │
│ │                                                 │ │
│ │ ┌──────────┐ ┌──────────┐ ┌──────────┐         │ │
│ │ │ Ames     │ │ Eyre     │ │ Gall     │         │ │
│ │ │ (P2P net)│ │ (HTTP)   │ │ (apps)   │         │ │
│ │ ├──────────┤ ├──────────┤ ├──────────┤         │ │
│ │ │ Behn     │ │ Clay     │ │ Iris     │         │ │
│ │ │ (timers) │ │ (files)  │ │ (HTTP    │         │ │
│ │ │          │ │          │ │  client) │         │ │
│ │ ├──────────┤ ├──────────┤ ├──────────┤         │ │
│ │ │ Dill     │ │ Jael     │ │ Khan     │         │ │
│ │ │ (term)   │ │ (keys)   │ │ (threads)│         │ │
│ │ └──────────┘ └──────────┘ └──────────┘         │ │
│ └─────────────────────────────────────────────────┘ │
│                                                     │
│ ┌─────────────────────────────────────────────────┐ │
│ │ Nock (Virtual Machine)                          │ │
│ │ Deterministic combinator calculus                │ │
│ └─────────────────────────────────────────────────┘ │
│                                                     │
│ ┌─────────────────────────────────────────────────┐ │
│ │ Vere (Runtime / Interpreter)                    │ │
│ │ C implementation, manages I/O, event log, state │ │
│ └─────────────────────────────────────────────────┘ │
└──────────────────────┬──────────────────────────────┘
                       │
          ┌────────────┼────────────┐
          │            │            │
    ┌─────▼─────┐ ┌───▼───┐ ┌─────▼─────┐
    │ Ames      │ │ Eyre  │ │ Other     │
    │ (UDP P2P) │ │ (HTTP │ │ ships     │
    │ E2E enc.  │ │  API) │ │ (peers)   │
    └───────────┘ └───┬───┘ └───────────┘
                      │
               ┌──────▼──────┐
               │ External    │
               │ Client      │
               │ (Bot, Web   │
               │  UI, CLI)   │
               └─────────────┘
```

### Arvo Kernel Vanes

| Vane | Purpose |
|------|---------|
| **Ames** | Peer-to-peer encrypted networking (UDP-based) |
| **Eyre** | HTTP server — external API for web clients and bots |
| **Gall** | Application framework — stateful agents (apps) |
| **Behn** | Timer system |
| **Clay** | Typed filesystem with revision control |
| **Iris** | HTTP client — outbound requests |
| **Jael** | Key management and Azimuth state |
| **Khan** | Thread execution (one-off computations) |
| **Dill** | Terminal driver |
| **Lick** | IPC for external processes |

### Message Flow (Ship-to-Ship)

1. Sender's Gall agent produces a message (e.g., chat post in Groups app)
2. Ames encrypts the message using the recipient ship's public key (from Azimuth/Jael)
3. Message sent as UDP packet to recipient's IP (resolved via galaxy/star infrastructure)
4. Recipient's Ames decrypts and delivers to the target Gall agent
5. Acknowledgment sent back through Ames (guaranteed delivery with retry)

### Message Flow (External Client via HTTP)

1. External client authenticates with Eyre using `+code` (ship's web login code)
2. Client subscribes to SSE event stream for real-time updates
3. Client sends actions via PUT/POST with JSON payloads (poked through `mark` system)
4. Eyre routes actions to the appropriate Gall agent
5. Agent processes action, updates state, and emits events on subscribed paths

## Urbit ID (Azimuth)

### Address Hierarchy

Urbit's identity system is a hierarchical address space registered on Ethereum:

| Type | Count | Name format | Example | Role |
|------|-------|-------------|---------|------|
| Galaxy | 256 | ~zod, ~nec | `~zod` | Network infrastructure, issue stars |
| Star | 65,536 | ~marzod | `~marzod` | Peer discovery, issue planets, software distribution |
| Planet | ~4.3 billion | ~sampel-palnet | `~sampel-palnet` | Individual users (permanent identity) |
| Moon | 2^32 per planet | ~doznec-sampel-palnet | `~doznec-sampel-palnet` | Sub-identities, devices, bots |
| Comet | 2^128 | ~random-128bit | `~dozzod-dozzod-...` | Free, temporary, untrusted |

### Key Properties

- **NFT-based ownership**: Planets, stars, and galaxies are ERC-721 tokens on Ethereum L1
- **Transferable**: Identity can be sold, gifted, or transferred on-chain
- **Hierarchical sponsorship**: Planets are sponsored by stars, stars by galaxies — sponsors provide peer discovery and software updates
- **Key rotation**: Networking keys can be rotated on-chain without losing identity
- **Deterministic names**: Ship names are derived from their Azimuth point number via a phonemic encoding

### Identity for Bots

For bot integration, use a **moon** (sub-identity of your planet):

- Free to create (no Ethereum transaction needed)
- Inherits networking from parent planet
- Disposable — can be destroyed and recreated
- Identified as `~moon-name-parent-planet`

```text
# In your ship's dojo (CLI)
|moon ~bot-name
```

This creates a moon keyfile that can boot a separate ship instance for the bot.

## Hoon / Nock Programming

### Nock

Nock is the lowest layer — a minimal combinator calculus with 12 opcodes. All Urbit computation reduces to Nock. You rarely write Nock directly, but understanding it helps debug:

- **Deterministic**: Same input always produces same output
- **Functional**: No side effects in the VM itself
- **Minimal**: Entire spec fits on a napkin (12 rules)

### Hoon

Hoon is the high-level language that compiles to Nock:

```hoon
::  Basic Hoon syntax examples
::
::  Comments start with ::
::  Runes are two-character digraphs (e.g., |= is "bartis")
::
|=  n=@ud        ::  gate (function) taking an unsigned decimal
^-  @ud          ::  return type annotation
?:  =(n 0)       ::  conditional (if n == 0)
  1              ::  then: return 1
(mul n $(n (dec n)))  ::  else: n * recurse(n-1)
```

**Key concepts**:

| Concept | Description |
|---------|-------------|
| **Runes** | Two-character operators (e.g., `\|=` gate, `%-` function call, `^-` type cast) |
| **Cores** | Fundamental code unit — a battery (code) paired with a payload (data) |
| **Gates** | Functions — a core with a single arm `$` |
| **Arms** | Named computations within a core |
| **Faces** | Named bindings (like variable names) |
| **Molds** | Types — functions that validate/normalize data |
| **Marks** | File types with conversion rules (like MIME types for Urbit) |
| **Subjects** | The environment/context available to an expression |

### Gall Agents

Gall agents are stateful applications — the primary way to build on Urbit:

```hoon
::  Minimal Gall agent skeleton
::
/+  default-agent
|%
+$  state-0  [%0 messages=(list @t)]
--
%-  agent:dbug
^-  agent:gall
|_  =bowl:gall
+*  this  .
    def   ~(. (default-agent this %|) bowl)
::
++  on-init   `this(state [%0 ~])
++  on-save   !>(state)
++  on-load   |=(old=vase `this(state !<(state-0 old)))
++  on-poke
  |=  [=mark =vase]
  ?+  mark  (on-poke:def mark vase)
    %noun
    =/  msg  !<(@t vase)
    `this(messages [msg messages.state])
  ==
++  on-watch  on-watch:def
++  on-leave  on-leave:def
++  on-peek   on-peek:def
++  on-agent  on-agent:def
++  on-arvo   on-arvo:def
++  on-fail   on-fail:def
--
```

**Agent arms** (lifecycle hooks):

| Arm | Purpose |
|-----|---------|
| `on-init` | Called once when agent is first started |
| `on-save` | Serialize state for persistence |
| `on-load` | Deserialize state (handles upgrades) |
| `on-poke` | Handle incoming actions (from local or remote) |
| `on-watch` | Handle subscription requests |
| `on-leave` | Handle subscription cancellations |
| `on-peek` | Handle scry (read-only state queries) |
| `on-agent` | Handle responses from other agents |
| `on-arvo` | Handle kernel responses |
| `on-fail` | Handle crash recovery |

### Learning Curve

Hoon has a steep learning curve:

- Unfamiliar syntax (runes instead of keywords)
- Unique type system (molds, faces, subjects)
- Functional paradigm with no mutable state
- Limited tooling (no mainstream IDE support, basic LSP)
- Small community for help/examples

**Realistic timeline**: Expect 2-4 weeks of dedicated study to write basic Gall agents. The [Hoon School](https://docs.urbit.org/courses/hoon-school) and [App School](https://docs.urbit.org/courses/app-school) courses are the recommended path.

## HTTP API (Eyre)

### Authentication

Every ship has a web login code accessible from the dojo:

```text
+code
```

This returns a code like `lidlut-tabwed-pillex-ridlur`. Use it to authenticate HTTP sessions.

```bash
# Authenticate and get session cookie
curl -i -X POST http://localhost:8080/~/login \
  -d "password=lidlut-tabwed-pillex-ridlur"

# Response includes set-cookie header with urbauth-~sampel-palnet=<token>
```

### Subscribing to Events (SSE)

```bash
# Subscribe to a Gall agent's path via Server-Sent Events
curl -N -H "Cookie: urbauth-~sampel-palnet=<token>" \
  http://localhost:8080/~/channel/my-channel-1234 \
  --data '[{"id":1,"action":"subscribe","ship":"sampel-palnet","app":"chat-store","path":"/mailbox/~sampel-palnet/general"}]'
```

### Sending Actions (Poke)

```bash
# Poke a Gall agent with a JSON action
curl -X PUT http://localhost:8080/~/channel/my-channel-1234 \
  -H "Cookie: urbauth-~sampel-palnet=<token>" \
  -H "Content-Type: application/json" \
  -d '[{
    "id": 2,
    "action": "poke",
    "ship": "sampel-palnet",
    "app": "chat-hook",
    "mark": "chat-action",
    "json": {
      "message": {
        "path": "/~sampel-palnet/general",
        "envelope": {
          "uid": "0v1.abcde.fghij",
          "number": 1,
          "author": "~sampel-palnet",
          "when": 1234567890000,
          "letter": {"text": "Hello from external client"}
        }
      }
    }
  }]'
```

### Channel Protocol

Eyre uses a channel-based protocol for bidirectional communication:

| Action | Method | Description |
|--------|--------|-------------|
| `poke` | PUT | Send action to a Gall agent |
| `subscribe` | PUT | Subscribe to an agent's event path |
| `unsubscribe` | PUT | Cancel a subscription |
| `ack` | PUT | Acknowledge received events (prevents replay) |
| `delete` | DELETE | Close the channel |

Events arrive via SSE on the channel URL. Each event has an incrementing ID that must be acknowledged.

### Scry (Read-Only Queries)

```bash
# Read agent state without side effects
curl -H "Cookie: urbauth-~sampel-palnet=<token>" \
  http://localhost:8080/~/scry/chat-store/mailbox/~sampel-palnet/general.json
```

Scry is a synchronous, read-only query into agent state — useful for polling current state without subscribing.

### JavaScript/TypeScript Client

The `@urbit/http-api` package provides a typed client:

```bash
npm install @urbit/http-api
```

```typescript
import Urbit from "@urbit/http-api";

// Connect to ship
const api = await Urbit.authenticate({
  ship: "sampel-palnet",
  url: "http://localhost:8080",
  code: "lidlut-tabwed-pillex-ridlur",
});

// Subscribe to events
api.subscribe({
  app: "chat-store",
  path: "/mailbox/~sampel-palnet/general",
  event: (data) => {
    console.log("New event:", data);
  },
  err: (error) => {
    console.error("Subscription error:", error);
  },
  quit: () => {
    console.log("Subscription closed");
  },
});

// Poke (send action)
await api.poke({
  app: "chat-hook",
  mark: "chat-action",
  json: {
    message: {
      path: "/~sampel-palnet/general",
      envelope: {
        uid: "0v1.abcde.fghij",
        number: 1,
        author: "~sampel-palnet",
        when: Date.now(),
        letter: { text: "Hello from TypeScript" },
      },
    },
  },
});

// Scry (read state)
const state = await api.scry({ app: "chat-store", path: "/keys" });
```

## Installation

### Binary (Recommended)

```bash
# Linux (x86_64)
curl -L https://urbit.org/install/linux-x86_64/latest -o urbit
chmod +x urbit
./urbit

# macOS (Apple Silicon)
curl -L https://urbit.org/install/macos-aarch64/latest -o urbit
chmod +x urbit
./urbit

# macOS (Intel)
curl -L https://urbit.org/install/macos-x86_64/latest -o urbit
chmod +x urbit
./urbit
```

### Boot a Ship

```bash
# Boot a comet (free, temporary identity)
./urbit -c mycomet

# Boot a planet (requires keyfile from Bridge)
./urbit -w sampel-palnet -k sampel-palnet-1.key

# Boot a moon (requires parent planet's dojo)
# On parent: |moon ~bot-name
# Then: ./urbit -w bot-name-sampel-palnet -k bot-name-sampel-palnet-1.key
```

### Docker

```bash
docker run -d \
  --name urbit \
  -p 8080:80 \
  -v urbit-data:/urbit \
  tloncorp/urbit:latest
```

### Hosting Providers

For users who do not want to self-host:

| Provider | Description |
|----------|-------------|
| [Tlon](https://tlon.io/) | Official hosting by Urbit's primary developer |
| [Native Planet](https://www.nativeplanet.io/) | Dedicated Urbit hardware appliances |
| [Red Horizon](https://redhorizon.com/) | Cloud hosting |

### Dojo (CLI)

Once booted, the dojo is the ship's command-line interface:

```text
::  Check ship identity
our

::  Check web login code
+code

::  Install an app from a distribution ship
|install ~paldev %pals

::  List installed desks (app packages)
+vats

::  Send a chat message (via Groups app)
:groups &groups-action [%channel-post [~sampel-palnet %general] ...]
```

## Limitations

### Steep Learning Curve

Urbit's programming model (Hoon/Nock) is unlike any mainstream language. The rune-based syntax, subject-oriented programming, and unique type system require significant investment to learn. This is the primary barrier to building custom integrations.

### Niche Ecosystem

- Small developer community compared to Matrix, SimpleX, or XMTP
- Limited third-party libraries and tooling
- Few production-grade bot frameworks
- IDE support is minimal (basic syntax highlighting, experimental LSP)

### Limited Bot Tooling

There is no dedicated "bot SDK" equivalent to SimpleX's WebSocket API or XMTP's Agent SDK. Building a bot requires either:

1. **Custom Gall agent** (Hoon) — full native integration but requires learning Hoon
2. **HTTP API bridge** (any language) — connect via Eyre, but limited to what the HTTP API exposes
3. **Airlock libraries** — `@urbit/http-api` (JS/TS), `urbit-api` (Python), `urbit-q` (Rust) — thin HTTP wrappers

### Performance

- Nock interpretation is slower than native code (jet system mitigates for common operations)
- Ship boot and OTA updates can be slow (minutes to hours for large state)
- Memory usage grows with state size — ships with years of data can consume significant RAM

### Infrastructure Requirements

Each ship is a long-running process that needs:

- Persistent storage (event log grows over time)
- Stable network connectivity (for Ames peer-to-peer communication)
- Port forwarding or hosting provider for inbound connections
- Regular OTA updates (applied automatically but can be disruptive)

### App Ecosystem Maturity

- Groups (chat/forums) is the primary social app — functional but less polished than mainstream alternatives
- App distribution is decentralized (install from other ships) but discovery is limited
- No push notifications in the traditional sense — ships are always-on servers

### Ethereum Dependency

Planet acquisition requires an Ethereum transaction (or receiving one from a star owner). Gas costs fluctuate. Layer 2 solutions (Naive Rollups) reduce cost but add complexity.

## Security Considerations

### Threat Model

Urbit protects against:

- **Server compromise**: No central servers — each ship is independently operated
- **Identity theft**: Urbit ID keys are on Ethereum; identity cannot be forged without private key compromise
- **Network surveillance**: Ames encrypts all ship-to-ship traffic end-to-end
- **Metadata collection**: No third-party servers to collect metadata — your star sees connection requests but not message content
- **Platform deplatforming**: Identity is an NFT you own; no platform can revoke it

Urbit does **not** protect against:

- **Device/host compromise**: Ship state on disk contains all data in the clear (event log)
- **Ethereum key compromise**: Attacker with master ticket can transfer identity and rotate keys
- **Star-level censorship**: A malicious star could refuse to route for its planets (mitigated by star transfer)
- **Traffic analysis**: Ames traffic patterns (timing, volume) are visible to network observers
- **Galaxy/star collusion**: The top of the hierarchy has structural power over routing and updates

### Privacy Assessment

| Property | Rating | Notes |
|----------|--------|-------|
| E2E encryption | Strong | Ames encrypts all inter-ship communication |
| Decentralization | Maximum | Each user runs their own server |
| Identity sovereignty | Maximum | Urbit ID is an NFT — user owns it outright |
| Metadata protection | Strong | No central servers collecting metadata |
| Anonymity | Weak | Urbit IDs are pseudonymous but persistent and linkable |
| Infrastructure sovereignty | Maximum | Self-hosted; no dependency on any platform |
| Censorship resistance | Strong | Hierarchical sponsorship is the main vector; star transfer mitigates |

### Operational Security

- Store master ticket (Ethereum key) in cold storage — it controls identity transfer
- Use management proxy for routine key operations
- Run ship on trusted infrastructure (VPS you control, or dedicated hardware)
- Keep ship updated — OTA updates include security patches
- Use moons for bot/service identities to isolate from primary planet
- Back up ship pier (data directory) regularly — loss means loss of all state

## Integration with aidevops

### Current Status

Urbit integration requires either a custom Hoon agent or an HTTP API bridge via Eyre. There is no turnkey bot framework. The HTTP API (`@urbit/http-api`) is the most practical path for external integration.

### Potential Architecture

```text
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ Urbit Ship       │     │ HTTP Bridge      │     │ aidevops Runner  │
│ (~sampel-palnet) │     │ (Node.js/Bun)    │     │                  │
│                  │     │                  │     │ runner-helper.sh │
│ Groups app /     │────▶│ 1. SSE subscribe │────▶│ → AI session     │
│ custom agent     │     │ 2. Parse message │     │ → response       │
│                  │◀────│ 3. Dispatch      │◀────│                  │
│ Chat channel     │     │ 4. Poke reply    │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Bot via HTTP API (TypeScript)

```typescript
import Urbit from "@urbit/http-api";

const api = await Urbit.authenticate({
  ship: "sampel-palnet",
  url: "http://localhost:8080",
  code: "lidlut-tabwed-pillex-ridlur",  // from +code in dojo
});

// Subscribe to chat messages
api.subscribe({
  app: "groups",
  path: "/groups/~sampel-palnet/my-group/channels/chat/~sampel-palnet/general/posts",
  event: async (data) => {
    // Parse incoming message
    const message = extractMessage(data);

    // Dispatch to aidevops runner
    const result = await dispatchToRunner(message);

    // Reply via poke
    await api.poke({
      app: "channels",
      mark: "channel-action",
      json: buildReply(result),
    });
  },
});
```

### Use Cases for aidevops

| Scenario | Value |
|----------|-------|
| Sovereign AI assistant | AI bot running on user's own ship — no third-party servers |
| Private group automation | Automate tasks in Urbit Groups channels |
| Decentralized dispatch | Use Ames for agent-to-agent communication without central infrastructure |
| Identity-verified commands | Urbit ID provides cryptographic authentication for command authorization |
| Long-term personal computing | Ship persists indefinitely — bot state survives across years |

### Matterbridge Integration

Urbit does not have a native Matterbridge adapter. A custom adapter could be built using `@urbit/http-api` and Matterbridge's REST API, following the same pattern as the SimpleX adapter. This would bridge Urbit Groups channels to Matrix, Telegram, Discord, and other platforms.

## Related

- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, no identifiers)
- `services/communications/matrix-bot.md` — Matrix bot integration (federated)
- `services/communications/xmtp.md` — XMTP (Web3 messaging, wallet identity)
- `services/communications/bitchat.md` — Bitchat (Bluetooth mesh, offline)
- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `tools/security/opsec.md` — Operational security guidance
- Urbit Docs: https://docs.urbit.org/
- Urbit Developer Docs: https://developers.urbit.org/
- Urbit GitHub: https://github.com/urbit
- Azimuth (Urbit ID): https://azimuth.network/
- Hoon School: https://docs.urbit.org/courses/hoon-school
- App School: https://docs.urbit.org/courses/app-school
- HTTP API Reference: https://docs.urbit.org/system/kernel/eyre/reference/external-api-ref
