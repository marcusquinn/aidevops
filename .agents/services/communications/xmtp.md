---
description: XMTP — decentralized messaging protocol with quantum-resistant E2E encryption, MLS-based group chats, wallet/DID identity, agent SDK (TypeScript), native payments, spam consent
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

# XMTP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Decentralized messaging protocol — wallet/DID identity, quantum-resistant E2E encryption, native payments
- **License**: MIT (SDKs), open-source protocol
- **SDKs**: Agent SDK (Node.js), Browser SDK, Node SDK, React Native, Android (Kotlin), iOS (Swift)
- **Agent SDK**: `@xmtp/agent-sdk` (npm) — event-driven middleware architecture
- **Protocol**: MLS (Messaging Layer Security, IETF RFC 9420) with post-quantum hybrid encryption
- **Network**: Decentralized node operators, ~$5 per 100K messages
- **Environments**: `local` (Docker), `dev` (test network), `production`
- **Repo**: [github.com/xmtp](https://github.com/xmtp) (org) | [github.com/xmtp/xmtp-js](https://github.com/xmtp/xmtp-js) (SDKs)
- **Website**: [xmtp.org](https://xmtp.org/) | **Docs**: [docs.xmtp.org](https://docs.xmtp.org/)
- **Playground**: [xmtp.chat](https://xmtp.chat/) (test agents and chat)
- **MCP server**: [github.com/xmtp/xmtp-docs-mcp](https://github.com/xmtp/xmtp-docs-mcp) (AI-ready docs)

**Key differentiator**: XMTP is identity-agnostic (wallets, passkeys, DIDs, social accounts) with native digital currency support. Messages and payments flow in the same conversation. The protocol uses MLS (the same standard behind Signal and WhatsApp group encryption) with post-quantum extensions, audited by NCC Group.

**When to use XMTP vs other protocols**:

| Criterion | XMTP | SimpleX | Matrix | Bitchat |
|-----------|------|---------|--------|---------|
| Identity model | Wallet/DID/passkey | None | `@user:server` | Pubkey fingerprint |
| Encryption | MLS + post-quantum hybrid | Double ratchet (X3DH) | Megolm (optional) | Noise XX |
| Native payments | Yes (in-conversation) | No | No | No |
| Spam protection | Protocol-level consent | Per-connection | Server-side | Physical proximity |
| Agent/bot SDK | First-class (`@xmtp/agent-sdk`) | WebSocket JSON API | `matrix-bot-sdk` | None |
| Decentralization | Node operators (paid) | Stateless relays | Federated servers | BLE mesh (no internet) |
| Best for | Web3 apps, AI agents, payments | Maximum privacy | Team collaboration | Offline/local comms |

<!-- AI-CONTEXT-END -->

## Architecture

```text
┌──────────────────────┐     ┌──────────────────────┐
│ Chat App / Agent      │     │ Chat App / Agent      │
│ (Browser, Node, RN,   │     │ (Browser, Node, RN,   │
│  Android, iOS)         │     │  Android, iOS)         │
│                        │     │                        │
│ ┌────────────────────┐ │     │ ┌────────────────────┐ │
│ │ XMTP SDK           │ │     │ │ XMTP SDK           │ │
│ │ ├─ MLS encryption  │ │     │ │ ├─ MLS encryption  │ │
│ │ ├─ Content types   │ │     │ │ ├─ Content types   │ │
│ │ ├─ Consent mgmt    │ │     │ │ ├─ Consent mgmt    │ │
│ │ └─ Local SQLite DB │ │     │ │ └─ Local SQLite DB │ │
│ └────────────────────┘ │     │ └────────────────────┘ │
└──────────┬─────────────┘     └──────────┬─────────────┘
           │                              │
           │  E2E encrypted (MLS)         │
           │                              │
    ┌──────▼──────────────────────────────▼──────┐
    │         XMTP Network (Decentralized)       │
    │                                            │
    │  ┌────────┐  ┌────────┐  ┌────────┐       │
    │  │ Node 1 │  │ Node 2 │  │ Node 3 │  ...  │
    │  └────────┘  └────────┘  └────────┘       │
    │                                            │
    │  Independent operators, globally distributed│
    │  ~$5 per 100K messages                     │
    └────────────────────────────────────────────┘
```

**Message flow**:

1. Sender's SDK encrypts message client-side using MLS group state
2. Encrypted message sent to XMTP network nodes
3. Nodes relay and store messages for offline recipients
4. Recipient's SDK retrieves and decrypts messages locally
5. Content types (text, reactions, attachments, transactions) decoded by SDK
6. Consent system filters spam at protocol level (allow/block per sender)

## Protocol

### MLS (Messaging Layer Security)

XMTP implements [IETF RFC 9420 (MLS)](https://www.rfc-editor.org/rfc/rfc9420) for group encryption:

- **Post-quantum hybrid encryption**: Protects against "harvest now, decrypt later" attacks
- **Perfect forward secrecy**: Past messages cannot be decrypted if current keys are compromised
- **Post-compromise security**: Security recovers after a key compromise
- **Scalable groups**: Tree-based key management (O(log n) operations per member change)
- **Audited**: NCC Group reviewed XMTP's MLS implementation (same firm that audits Signal and WhatsApp)

### Identity

XMTP works with any decentralized identifier (DID):

| Identity type | Example |
|---------------|---------|
| EOA wallet | `0x1234...abcd` |
| Smart contract wallet | Account abstraction wallets |
| ENS | `alice.eth` |
| Passkey | Device-bound credential |
| Social account | Via DID resolver |
| Custom DID | Any DID method |

No platform lock-in — developers connect their existing identity model to XMTP.

### Content Types

Rich content beyond plain text:

| Content type | Package | Description |
|-------------|---------|-------------|
| Text | `content-type-text` | Plain text messages |
| Reaction | `content-type-reaction` | Emoji reactions to messages |
| Reply | `content-type-reply` | Threaded replies |
| Read receipt | `content-type-read-receipt` | Read confirmations |
| Remote attachment | `content-type-remote-attachment` | Files stored off-network |
| Transaction reference | `content-type-transaction-reference` | On-chain transaction links |
| Group updated | `content-type-group-updated` | Group membership changes |

Custom content types can be built using `content-type-primitives`.

### Consent and Spam Protection

Protocol-level consent system:

- Users explicitly allow or block senders across the entire XMTP network
- All consent state is encrypted and user-controlled
- Developers get network-level view of allowed/blocked senders
- No server-side filtering — consent enforced client-side by SDK

## Installation

### Agent SDK (Recommended for Bots)

```bash
# Create project
mkdir my-agent && cd my-agent
npm init --init-type=module -y

# Install SDK and TypeScript tooling
npm i @xmtp/agent-sdk
npm i -D typescript tsx @types/node
```

### Browser SDK

```bash
npm i @xmtp/browser-sdk
```

### Node SDK

```bash
npm i @xmtp/node-sdk
```

### React Native SDK

```bash
npm i @xmtp/react-native-sdk
```

### Mobile SDKs

- **Android**: [docs.xmtp.org/chat-apps/sdks/android](https://docs.xmtp.org/chat-apps/sdks/android)
- **iOS**: [docs.xmtp.org/chat-apps/sdks/ios](https://docs.xmtp.org/chat-apps/sdks/ios)

## Agent SDK Usage

### Environment Variables

```bash
# .env
XMTP_ENV=dev                    # local | dev | production
XMTP_WALLET_KEY=0x...           # EOA wallet private key
XMTP_DB_ENCRYPTION_KEY=0x...    # 64 hex chars (32 bytes) for local SQLite
```

### Basic Agent

```typescript
import { Agent, getTestUrl } from "@xmtp/agent-sdk";

// Create agent from .env
const agent = await Agent.createFromEnv();

// Respond to text messages
agent.on("text", async (ctx) => {
  await ctx.conversation.sendText("Hello from XMTP agent!");
});

// Log when ready
agent.on("start", () => {
  console.log(`Address: ${agent.address}`);
  console.log(`Test: ${getTestUrl(agent.client)}`);
});

await agent.start();
```

### Event-Driven Middleware

The Agent SDK uses an event-driven architecture with middleware:

```typescript
// Handle different content types
agent.on("text", async (ctx) => {
  const text = ctx.content;
  // Process text message
});

agent.on("reaction", async (ctx) => {
  // Handle reaction
});

agent.on("reply", async (ctx) => {
  // Handle threaded reply
});

// Group chat events
agent.on("group_updated", async (ctx) => {
  // Handle member changes
});
```

### Sending Messages

```typescript
// Send text
await ctx.conversation.sendText("Hello!");

// Send to a specific address
const conversation = await agent.client.conversations.newDm(
  "0xRecipientAddress"
);
await conversation.sendText("Direct message");

// Group chats
const group = await agent.client.conversations.newGroup([
  "0xMember1",
  "0xMember2",
]);
await group.sendText("Group message");
```

### Local Database

Each agent maintains a local SQLite database for device identity and message history:

- Created in `dbPath` (default: `./`)
- **Must persist across restarts and deployments**
- Limited to 10 installations per inbox — losing the DB creates a new installation
- Encrypted with `XMTP_DB_ENCRYPTION_KEY`

### Key Constraints

- **Wallet key required**: Agent needs an EOA wallet private key for identity
- **Local DB persistence**: Database files must survive restarts (use persistent volumes in Docker)
- **Installation limit**: 10 installations per inbox — do not recreate DBs unnecessarily
- **Network cost**: ~$5 per 100K messages on production network
- **Consent**: New conversations require recipient consent before messages are visible

## Deployment

### Process Management

Use PM2 or similar for production:

```bash
npm i -g pm2
pm2 start src/agent.ts --interpreter tsx --name xmtp-agent
pm2 save
pm2 startup
```

### Docker

```dockerfile
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
# Persist database files
VOLUME /app/data
ENV XMTP_DB_PATH=/app/data
CMD ["npx", "tsx", "src/agent.ts"]
```

### Security

- Store wallet key and DB encryption key in secure secret management (gopass, env vars)
- Never expose wallet private key in logs or output
- Use `dev` environment for testing, `production` for live agents
- Rate limits apply per agent — see [docs.xmtp.org/agents/deploy/rate-limits](https://docs.xmtp.org/agents/deploy/rate-limits)

## Production Apps Using XMTP

| App | Description |
|-----|-------------|
| [Base App](https://base.app/) | Coinbase L2 messaging |
| [World App](https://world.org/) | World (formerly Worldcoin) verified human messaging |
| [Convos](https://converse.xyz/) | XMTP-native messenger |
| [Zora](https://zora.co/) | NFT marketplace messaging |
| [xmtp.chat](https://xmtp.chat/) | Developer playground |

55M+ connected users, 4,500+ developers, 1,700+ production mini-apps.

## Comparison with Signal Protocol

| Aspect | XMTP (MLS) | Signal (Double Ratchet) | SimpleX |
|--------|-----------|------------------------|---------|
| Group encryption | MLS tree (O(log n)) | Sender keys | Per-member ratchet |
| Post-quantum | Hybrid PQ/classical | Not yet | Not yet |
| Identity | Wallet/DID | Phone number | None |
| Payments | Native | No | No |
| Decentralization | Node operators | Centralized | Stateless relays |
| Spam protection | Protocol-level consent | Phone verification | Per-connection |
| Bot/agent SDK | First-class | No official SDK | WebSocket API |
| Audit | NCC Group (MLS) | Multiple audits | Multiple audits |

## Limitations

### Wallet Requirement

Agents and users need a wallet (EOA) or DID for identity. This is a barrier for non-crypto users, though passkey support reduces friction.

### Network Cost

Production messaging costs ~$5 per 100K messages, paid to node operators. Free on `dev` network for testing.

### Installation Limit

Each inbox is limited to 10 installations (devices/instances). Losing the local database and recreating counts as a new installation. This is a hard limit.

### No Offline/Mesh Support

XMTP requires internet connectivity. Unlike Bitchat, there is no offline or mesh networking capability.

### Ecosystem Maturity

While growing rapidly (55M users), the ecosystem is younger than Matrix. Some content types and features are still evolving.

### Web3 Dependency

The protocol is designed around blockchain identity. Non-Web3 use cases may find the wallet requirement unnecessary overhead, though passkey-based identity reduces this friction.

## Integration with aidevops

### Bot/Agent Integration

XMTP's Agent SDK is well-suited for aidevops runner dispatch:

```typescript
import { Agent } from "@xmtp/agent-sdk";

const agent = await Agent.createFromEnv();

agent.on("text", async (ctx) => {
  const prompt = ctx.content;

  // Dispatch to aidevops runner
  // Similar pattern to Matrix bot dispatch
  const result = await dispatchToRunner(prompt);
  await ctx.conversation.sendText(result);
});

await agent.start();
```

### Potential Architecture

```text
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│ XMTP Chat        │     │ XMTP Agent       │     │ aidevops Runner  │
│ (Base, World,    │     │ (Node.js)        │     │                  │
│  Convos, etc.)   │     │                  │     │ runner-helper.sh │
│                  │────▶│ 1. Receive msg   │────▶│ → AI session     │
│ User sends:      │     │ 2. Check consent │     │ → response       │
│ "Review auth.ts" │◀────│ 3. Dispatch      │◀────│                  │
│                  │     │ 4. Reply         │     │                  │
│ AI response      │     │                  │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Matterbridge Integration

XMTP does not have a native Matterbridge adapter. A custom adapter could be built using the Node SDK and Matterbridge's REST API, following the same pattern as the SimpleX adapter.

### Use Cases for aidevops

| Scenario | Value |
|----------|-------|
| Web3 project support | AI agents in Base/World/Convos for developer support |
| Payment-integrated bots | Accept payments for premium AI services in-conversation |
| Multi-agent coordination | XMTP group chats for agent-to-agent communication |
| Cross-platform dispatch | Bridge XMTP messages to aidevops runners via agent SDK |
| Spam-resistant public bots | Protocol-level consent prevents bot abuse |

## AI-Ready Documentation

XMTP provides tools for AI-assisted development:

- **MCP server**: [github.com/xmtp/xmtp-docs-mcp](https://github.com/xmtp/xmtp-docs-mcp) — use with Claude, ChatGPT, or other AI coding assistants
- **llms.txt**: Use-case-based documentation files for LLM context
- **Agent examples**: [github.com/xmtplabs/xmtp-agent-examples](https://github.com/xmtplabs/xmtp-agent-examples)
- **Starter template**: [github.com/xmtp/agent-sdk-starter](https://github.com/xmtp/agent-sdk-starter)

## Related

- `services/communications/simplex.md` — SimpleX Chat (zero-knowledge, no identifiers)
- `services/communications/matrix-bot.md` — Matrix bot integration (federated)
- `services/communications/bitchat.md` — Bitchat (Bluetooth mesh, offline)
- `services/communications/matterbridge.md` — Multi-platform chat bridge
- `tools/security/opsec.md` — Operational security guidance
- XMTP Docs: https://docs.xmtp.org/
- XMTP GitHub: https://github.com/xmtp
- XMTP Agent Examples: https://github.com/xmtplabs/xmtp-agent-examples
- XMTP MLS Audit: https://www.nccgroup.com/research-blog/public-report-xmtp-mls-implementation-review/
