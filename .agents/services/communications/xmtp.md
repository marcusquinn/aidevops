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

- **Type**: Decentralized messaging — wallet/DID identity, MLS + post-quantum E2E encryption, native payments
- **SDKs**: `@xmtp/agent-sdk` (bots), `@xmtp/browser-sdk`, `@xmtp/node-sdk`, React Native, [Android](https://docs.xmtp.org/chat-apps/sdks/android), [iOS](https://docs.xmtp.org/chat-apps/sdks/ios)
- **Protocol**: [IETF RFC 9420 MLS](https://www.rfc-editor.org/rfc/rfc9420) — perfect forward secrecy, post-compromise security, O(log n) group key ops, post-quantum hybrid (NCC Group audited)
- **Identity**: Any DID — EOA wallet, smart contract wallet, ENS, passkey, social account, custom DID method
- **Content types**: `text`, `reaction`, `reply`, `read-receipt`, `remote-attachment`, `transaction-reference`, `group-updated`. Custom via `content-type-primitives`.
- **Consent**: Allow/block senders network-wide. State encrypted, user-controlled, enforced client-side.
- **Network**: ~$5/100K messages on production; free on `dev`. Environments: `local` (Docker), `dev`, `production`
- **Limits**: 10 installations per inbox — losing local DB creates a new install (hard limit)
- **Docs**: [docs.xmtp.org](https://docs.xmtp.org/) | [xmtp.chat](https://xmtp.chat/) (playground) | [github.com/xmtp](https://github.com/xmtp)
- **Scale**: 55M+ users, 4,500+ developers, 1,700+ production mini-apps

**Key differentiator**: Identity-agnostic (wallets, passkeys, DIDs). Messages and payments in the same conversation. Post-quantum MLS — harvest-now-decrypt-later resistant.

## Protocol Comparison

| Criterion | XMTP | SimpleX | Matrix | Bitchat |
|-----------|------|---------|--------|---------|
| Identity | Wallet/DID/passkey | None | `@user:server` | Pubkey fingerprint |
| Encryption | MLS + post-quantum hybrid | Double ratchet (X3DH) | Megolm (optional) | Noise XX |
| Post-quantum | Yes | No | No | No |
| Native payments | Yes | No | No | No |
| Spam protection | Protocol-level consent | Per-connection | Server-side | Physical proximity |
| Agent/bot SDK | First-class (`@xmtp/agent-sdk`) | WebSocket JSON API | `matrix-bot-sdk` | None |
| Decentralization | Node operators (paid) | Stateless relays | Federated servers | BLE mesh |
| Best for | Web3 apps, AI agents, payments | Maximum privacy | Team collaboration | Offline/local comms |

<!-- AI-CONTEXT-END -->

## Installation

```bash
npm i @xmtp/agent-sdk && npm i -D typescript tsx @types/node  # bots/AI agents (recommended)
npm i @xmtp/browser-sdk   # browser
npm i @xmtp/node-sdk      # Node
```

## Agent SDK Usage

```bash
# .env
XMTP_ENV=dev                    # local | dev | production
XMTP_WALLET_KEY=0x...           # EOA wallet private key
XMTP_DB_ENCRYPTION_KEY=0x...    # 64 hex chars (32 bytes) — DB must survive restarts
```

```typescript
import { Agent } from "@xmtp/agent-sdk";

const agent = await Agent.createFromEnv();

agent.on("text", async (ctx) => { await ctx.conversation.sendText("Hello!"); });
agent.on("reaction", async (ctx) => { /* handle reaction */ });
agent.on("reply", async (ctx) => { /* handle threaded reply */ });
agent.on("group_updated", async (ctx) => { /* handle member changes */ });
agent.on("start", () => console.log(`Address: ${agent.address}`));

await agent.start();

// DM and group
const dm = await agent.client.conversations.newDm("0xRecipient");
await dm.sendText("Direct message");
const group = await agent.client.conversations.newGroup(["0xMember1", "0xMember2"]);
await group.sendText("Group message");
```

## Deployment

```bash
pm2 start src/agent.ts --interpreter tsx --name xmtp-agent && pm2 save && pm2 startup
```

**Security**: Store `XMTP_WALLET_KEY` and `XMTP_DB_ENCRYPTION_KEY` in gopass/env vars. Never log private keys. Use `dev` for testing. Rate limits: [docs.xmtp.org/agents/deploy/rate-limits](https://docs.xmtp.org/agents/deploy/rate-limits).

## Integration with aidevops

**Architecture**: XMTP Chat → XMTP Agent (receive, check consent, dispatch) → aidevops Runner → reply.

**Matterbridge**: No native adapter. Build using Node SDK + Matterbridge REST API (same pattern as SimpleX adapter).

**Use cases**: Web3 project support (Base/World/Convos), payment-integrated bots, multi-agent coordination via group chats, spam-resistant public bots (protocol-level consent).

## Production Apps

[Base App](https://base.app/) · [World App](https://world.org/) · [Convos](https://convos.org/) · [Zora](https://zora.co/) · [xmtp.chat](https://xmtp.chat/)

## Resources & Related

- **MCP server**: [github.com/xmtp/xmtp-docs-mcp](https://github.com/xmtp/xmtp-docs-mcp)
- **Agent examples**: [github.com/xmtplabs/xmtp-agent-examples](https://github.com/xmtplabs/xmtp-agent-examples)
- **Starter**: [github.com/xmtp/agent-sdk-starter](https://github.com/xmtp/agent-sdk-starter)
- **MLS audit**: https://www.nccgroup.com/research-blog/public-report-xmtp-mls-implementation-review/
- `services/communications/convos.md` — Convos (XMTP-native, CLI agent mode)
- `services/communications/simplex.md` — SimpleX (zero-knowledge, no identifiers)
- `services/communications/matrix-bot.md` — Matrix bot integration
- `services/communications/bitchat.md` — Bitchat (Bluetooth mesh, offline)
- `services/communications/matterbridge.md` — Multi-platform chat bridge
