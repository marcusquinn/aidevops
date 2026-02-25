---
mode: subagent
---
# t1327: SimpleX Chat Agent and Command Integration

## Origin

- **Created:** 2026-02-25
- **Session:** claude-code:simplex-agent-planning
- **Created by:** marcusquinn (human)
- **Conversation context:** User requested a comprehensive SimpleX Chat integration for aidevops covering: secure remote device management, AI bots for direct/group channels, device-to-device agent comms, user setup assistance, voice/file/call capabilities, opsec guidance, upstream contributions, and multi-platform usage.

## What

A full SimpleX Chat integration for aidevops comprising:

1. **Subagent doc** (`.agents/services/communications/simplex.md`) — comprehensive knowledge base for SimpleX Chat capabilities, bot API, CLI, protocol, setup, and opsec
2. **Helper script** (`simplex-helper.sh`) — CLI wrapper for common SimpleX operations (install, configure, bot management, message sending, connection management)
3. **Bot framework** — TypeScript/Bun bot scaffold that connects to SimpleX CLI via WebSocket, handles aidevops slash commands, supports direct and group channels
4. **Mailbox transport adapter** — extend existing `mail-helper.sh` SQLite mailbox system to use SimpleX (and optionally Matrix) as a secure network transport for inter-agent communication across devices/machines
5. **Opsec agent** (`.agents/tools/security/opsec.md`) — operational security guidance cross-referencing existing aidevops security tools, plus NetBird, Mullvad/IVPN, Brave, and threat modeling
6. **Setup wizard** — guided `aidevops simplex init` flow for installing SimpleX CLI, creating bot profiles, configuring business addresses

## Why

SimpleX Chat is the most privacy-respecting messaging platform available — no user identifiers, no phone numbers, no central servers storing metadata. This makes it ideal for:

- **Secure remote AI agent control** — initiate sessions on remote devices running aidevops without exposing any management interface to the public internet
- **Private device-to-device agent communication** — agents on different machines can coordinate over public networks with zero metadata leakage
- **Business bot deployment** — customer support, information retrieval, and service bots with stronger privacy guarantees than Telegram/WhatsApp
- **Opsec-first communications** — for users who need secure channels that don't require trusting a central provider

No existing aidevops integration covers secure messaging. Matrix (existing agent) is federated but has user identifiers and server-side metadata. SimpleX fills the gap for zero-knowledge communications.

## How (Approach)

### Architecture

```
User (SimpleX mobile/desktop/CLI)
    |
    | SimpleX Protocol (E2E encrypted, no user IDs)
    |
SimpleX CLI (running as WebSocket server, port 5225)
    |
    | WebSocket JSON API
    |
aidevops SimpleX Bot (TypeScript/Bun process)
    |
    | Dispatches to:
    |--- aidevops CLI commands
    |--- AI model queries (via existing model routing)
    |--- File/voice/attachment handling
    |--- Group management
```

### Key Technical Details from Research

**Bot API** (from `bots/README.md`):
- SimpleX CLI runs as WebSocket server (`simplex-chat -p 5225`)
- Bot connects as standalone process, sends/receives JSON over WebSocket
- Commands use `corrId` for request/response correlation
- Events stream via `resp` field (NewChatItems for messages)
- Bot profile configured with `peerType: "bot"`, supports command menus
- TypeScript SDK available: `@simplex-chat/types` + `simplex-chat` npm package
- Business addresses create per-customer group chats (like dedicated support)

**Protocol** (from whitepaper):
- No user identifiers — connections via uni-directional queues
- Double ratchet E2E encryption (X3DH with Curve448, AES-GCM)
- 2-hop onion routing protects sender IP from recipient's server
- Servers are stateless — messages in memory only, deleted after delivery
- XFTP for file transfer (separate protocol)
- WebRTC for audio/video calls (E2E encrypted)

**CLI** (from docs/CLI.md):
- Install: `curl -o- https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh | bash`
- Database: SQLite files (`simplex_v1_chat.db`, `simplex_v1_agent.db`)
- Tor support: `-x` flag or `--socks-proxy`
- Custom SMP servers: `-s smp://fingerprint@host`
- Commands: `/c` (connect), `/g` (group), `/f` (file), `/ad` (address), etc.

### Slash Command Design

SimpleX bot commands use `/` prefix — same as aidevops/Claude Code. Differentiation strategy:

| Prefix | Scope | Examples |
|--------|-------|---------|
| `/` (in SimpleX) | SimpleX bot commands | `/help`, `/status`, `/ask`, `/run` |
| `//` (in SimpleX) | Quick command menu button | Tapping shows bot command menu |
| `/` (in Claude Code) | aidevops slash commands | `/define`, `/pr`, `/ready` |

No conflict because contexts are separate (SimpleX chat vs Claude Code terminal). Within SimpleX, the bot owns the `/` namespace.

**Starter bot commands:**

| Command | Description |
|---------|-------------|
| `/help` | Show available commands and usage |
| `/status` | Show aidevops system status (repos, services, supervisor) |
| `/ask <question>` | Ask AI a question (routes to appropriate model tier) |
| `/run <command>` | Execute an aidevops CLI command remotely |
| `/task <description>` | Create a new task in TODO.md |
| `/tasks` | List open tasks |
| `/deploy <project>` | Trigger deployment pipeline |
| `/logs <service>` | Fetch recent logs |
| `/alert <message>` | Send alert to configured channels |
| `/voice` | Process voice note attachment as query |
| `/file` | Process file attachment (analyze, store, etc.) |

**Group bot commands (additional):**

| Command | Description |
|---------|-------------|
| `/invite @user` | Invite user to group |
| `/role @user <role>` | Set member role |
| `/broadcast <message>` | Send to all connected contacts |
| `/moderate` | Enable/configure moderation |

### Interactive Features (Telegram-style)

SimpleX supports bot command menus with nested structure. Configuration via `/set bot commands`:

```
/set bot commands 'Help':/help,'System Status':/status,'Ask AI':{'Quick question':/'ask <question>','Detailed analysis':/'analyze <topic>'},'DevOps':{'Run command':/'run <command>','Deploy':/'deploy <project>','View logs':/'logs <service>'},'Tasks':{'New task':/'task <description>','List tasks':/tasks}
```

This creates a hierarchical menu users can tap through — similar to Telegram's inline keyboards but using SimpleX's native command menu system.

### Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `.agents/services/communications/simplex.md` | Create | Subagent doc — full SimpleX knowledge base |
| `.agents/tools/security/opsec.md` | Create | Operational security agent (broader than just SimpleX) |
| `.agents/scripts/simplex-helper.sh` | Create | CLI helper for SimpleX operations |
| `configs/mcp-templates/simplex.json` | Create | MCP config template (if we build an MCP server) |
| `subagent-index.toon` | Update | Register simplex and opsec subagents |
| `AGENTS.md` (both) | Update | Add to domain index |
| `TODO.md` | Update | Task entry |
| `todo/PLANS.md` | Update | Execution plan |

### Reference Patterns

- Follow `services/communications/matrix-bot.md` for messaging agent structure
- Follow `tools/security/ip-reputation.md` for security agent pattern
- Follow `scripts/ip-reputation-helper.sh` for helper script pattern with provider architecture
- Follow `bots/README.md` (SimpleX upstream) for bot API patterns
- Follow TypeScript SDK (`simplex-chat` npm) for bot implementation

## Acceptance Criteria

- [ ] Subagent doc `.agents/services/communications/simplex.md` covers: installation, CLI usage, bot API, business addresses, protocol overview, limitations, opsec integration, voice/file/call capabilities, multi-platform usage
  ```yaml
  verify:
    method: codebase
    pattern: "simplex"
    path: ".agents/services/communications/simplex.md"
  ```
- [ ] Helper script `simplex-helper.sh` provides: install, init, send, connect, group, bot-start, bot-stop, status subcommands
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/simplex-helper.sh && grep -c 'cmd_' .agents/scripts/simplex-helper.sh | awk '{exit ($1 >= 6) ? 0 : 1}'"
  ```
- [ ] Bot framework scaffold with WebSocket connection, command routing, event handling, and starter commands
  ```yaml
  verify:
    method: codebase
    pattern: "NewChatItems|APISendMessages"
    path: ".agents/scripts/"
  ```
- [ ] Opsec agent `.agents/tools/security/opsec.md` covers: threat modeling, SimpleX vs Matrix comparison, platform trust matrix, chat-connected AI security model (DM pairing, prompt injection defense, tool sandboxing, credential isolation, leak detection, exec approvals), cross-references to existing security/credentials/browser agents, Brave recommendation, operational practices
  ```yaml
  verify:
    method: codebase
    pattern: "opsec|operational security"
    path: ".agents/tools/security/opsec.md"
  ```
- [ ] Slash command differentiation documented — no conflicts between SimpleX bot `/` commands and aidevops `/` commands
  ```yaml
  verify:
    method: subagent
    prompt: "Review simplex.md for clear documentation of how SimpleX bot slash commands are differentiated from aidevops slash commands"
    files: ".agents/services/communications/simplex.md"
  ```
- [ ] Setup wizard flow documented for `aidevops simplex init`
  ```yaml
  verify:
    method: codebase
    pattern: "cmd_init|simplex init"
    path: ".agents/scripts/simplex-helper.sh"
  ```
- [ ] Limitations section covers: cross-device message visibility, single-profile-per-device, owner role recovery, group stability
  ```yaml
  verify:
    method: codebase
    pattern: "cross-device|single.*profile|owner.*role|Limitations"
    path: ".agents/services/communications/simplex.md"
  ```
- [ ] Upstream contribution guidance documented (issue templates, PR workflow, feedback logging)
  ```yaml
  verify:
    method: codebase
    pattern: "contribution|upstream|feedback"
    path: ".agents/services/communications/simplex.md"
  ```
- [ ] Subagent index and AGENTS.md updated with new entries
  ```yaml
  verify:
    method: codebase
    pattern: "simplex"
    path: "subagent-index.toon"
  ```
- [ ] Lint clean (`shellcheck` for scripts, markdown lint for docs)

## Context & Decisions

Key decisions from the conversation:

- **SimpleX over Signal/Telegram for secure comms**: SimpleX has no user identifiers at all — not even random ones. Signal requires phone numbers, Telegram requires phone numbers. SimpleX is the only option for truly anonymous agent-to-agent communication.
- **Bot via WebSocket API, not direct protocol**: SimpleX CLI acts as the protocol handler; our bot connects via local WebSocket. This is the officially supported approach and avoids reimplementing the complex SMP protocol.
- **TypeScript/Bun for bot, not Haskell**: The upstream advanced bot example is Haskell, but the TypeScript SDK exists and aligns with aidevops's Node/Bun ecosystem. The `simplex-chat` npm package provides typed client.
- **No MCP server for SimpleX**: CLI agents serve the same purpose without context bloat. MCP adds overhead (schema, tool registration, token cost per invocation) with no capability the bot + helper script don't already provide. The WebSocket bot IS the integration layer.
- **Extend existing mailbox, don't invent new protocol**: `mail-helper.sh` already has message types (task_dispatch, status_report, discovery, request, broadcast), agent registration, convoy tracking, and SQLite WAL performance. Add SimpleX/Matrix as transport adapters so the same mailbox protocol works across machines over encrypted channels.
- **Opsec as separate agent**: SimpleX is one tool in a broader opsec toolkit. The opsec agent cross-references existing aidevops security/credentials/browser agents (gopass, Bitwarden, SOPS, gocryptfs, CamoFox/anti-detect, proxy-integration, IP reputation, etc.) plus NetBird, Mullvad, IVPN, and Brave. Adds threat modeling guidance. Additional tools (Tor, YubiKey, Whonix, Tails) assessed as needs arise.
- **Slash command coexistence**: No technical conflict — SimpleX bot commands run in SimpleX chat context, aidevops commands run in terminal context. Document clearly to avoid user confusion.
- **Business address for multi-agent support**: SimpleX's business address feature creates per-customer group chats — ideal for support bots that can escalate to human agents.
- **Voice notes as input**: SimpleX supports voice messages as file attachments. Bot can receive these, transcribe via existing speech-to-speech capabilities, and respond.
- **Video/voice calls as future phase**: SimpleX supports WebRTC calls. Integration depends on aidevops gaining real-time audio/video processing capabilities (not yet available).
- **Cross-device limitation is real**: SimpleX cannot sync a profile across multiple devices simultaneously. Workaround: run CLI in cloud, connect from desktop via Remote Control Protocol. Document this clearly.

## Relevant Files

- `.agents/scripts/mail-helper.sh` — existing inter-agent mailbox system to extend with SimpleX/Matrix transport
- `.agents/services/communications/matrix-bot.md` — existing messaging agent pattern to follow
- `.agents/services/communications/twilio.md` — another comms agent for reference
- `.agents/services/networking/netbird.md` — existing mesh VPN agent (for opsec cross-reference)
- `.agents/tools/security/ip-reputation.md` — security agent pattern
- `.agents/tools/security/tirith.md` — security tool agent pattern
- `.agents/scripts/ip-reputation-helper.sh` — helper script pattern
- `.agents/scripts/anti-detect-helper.sh` — CamoFox/anti-detect helper (for opsec cross-reference)
- `.agents/tools/voice/speech-to-speech.md` — voice capabilities reference
- `subagent-index.toon` — where to register new subagents
- `.agents/AGENTS.md` — domain index to update

## Dependencies

- **Blocked by:** Nothing — this is greenfield
- **Blocks:** Future secure agent-to-agent communication, remote device management via chat
- **External:** SimpleX CLI binary (open source, installable via curl), optional: self-hosted SMP server for maximum privacy

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 2h | Protocol docs, bot API, TypeScript SDK, mail-helper.sh |
| Subagent doc (simplex.md) | 4h | Comprehensive knowledge base |
| Helper script (simplex-helper.sh) | 3h | CLI wrapper with subcommands |
| Bot framework scaffold | 4h | TypeScript/Bun WebSocket bot with command routing |
| Mailbox transport adapter | 3h | Extend mail-helper.sh with SimpleX/Matrix transports |
| Opsec agent (opsec.md) | 3h | Security guidance cross-referencing existing agents |
| Chat security (t1327.8-10) | 6h | Prompt injection, leak detection, exec approval |
| Integration/testing | 4h | Index updates, end-to-end tests, linting |
| **Total** | **~29h** | (ai:22h test:4h read:3h) |

## Research Notes

### SimpleX Protocol Key Facts

- **No user identifiers** — not even random ones. Connections are pairs of uni-directional queues.
- **Double ratchet** with X3DH (Curve448) + AES-GCM — same as Signal but with additional per-queue NaCl encryption layer
- **2-hop onion routing** — sender's IP hidden from recipient's server even without Tor
- **Servers are stateless** — messages held in memory only, deleted after delivery (configurable retention)
- **Queue rotation** — connections periodically rotate to fresh queues on potentially different servers
- **XFTP** — separate file transfer protocol, files split into chunks across multiple servers
- **WebRTC** — audio/video calls with E2E encryption, ICE candidates exchanged via chat protocol

### SimpleX Bot API Key Facts

- CLI runs as WebSocket server on configurable port
- JSON messages with `corrId` for request/response correlation
- Bot profile: `peerType: "bot"` distinguishes from regular users
- Command menus: hierarchical, configured via `/set bot commands` syntax
- Business addresses: per-customer group chats, bot can add team members
- File handling: bot can send/receive files (stored on CLI's filesystem)
- No authentication on WebSocket API — must be localhost or behind TLS proxy with basic auth
- TypeScript SDK: `simplex-chat` npm package with typed client

### Known Limitations

1. **Cross-device sync**: Cannot access same profile from multiple devices simultaneously. Workaround: CLI in cloud + Remote Control Protocol from desktop.
2. **Owner role recovery**: If device/data lost, group owner role cannot be recovered. Mitigation: create owner profiles on multiple devices.
3. **Group stability**: Decentralized groups can have delayed delivery, member list desync. Large groups (1000+) are experimental.
4. **No message search**: Messages are E2E encrypted, no server-side search. Local search only.
5. **Bot WebSocket API is unauthenticated**: Must run on localhost or behind authenticated reverse proxy.
6. **File size limits**: XFTP handles large files but there are practical limits based on server configuration.

### Opsec Tool Landscape (for opsec.md — existing aidevops tools + confirmed additions)

| Tool | Category | aidevops Agent |
|------|----------|----------------|
| SimpleX Chat | Messaging | `services/communications/simplex.md` (this task) |
| Matrix | Messaging | `services/communications/matrix-bot.md` |
| NetBird | Mesh VPN | `services/networking/netbird.md` |
| Mullvad VPN | VPN | Confirmed for use — assess and add agent as needed |
| IVPN | VPN | Confirmed for use — assess and add agent as needed |
| gopass | Secrets | `tools/credentials/gopass.md` |
| Bitwarden/Vaultwarden | Secrets | `tools/credentials/bitwarden.md`, `tools/credentials/vaultwarden.md` |
| SOPS | Encryption | `tools/credentials/sops.md` |
| gocryptfs | Encryption | `tools/credentials/gocryptfs.md` |
| Enpass | Secrets | `tools/credentials/enpass.md` |
| Brave | Browser | Recommended privacy browser (Tor window built-in) |
| CamoFox / Anti-detect | Browser | `tools/browser/anti-detect-browser.md`, `scripts/anti-detect-helper.sh` |
| Browser fingerprinting | Browser | `tools/browser/fingerprint-profiles.md` |
| Stealth patches | Browser | `tools/browser/stealth-patches.md` |
| Proxy integration | Network | `tools/browser/proxy-integration.md` |
| IP reputation | Security | `tools/security/ip-reputation.md` |
| CDN origin IP | Security | `tools/security/cdn-origin-ip.md` |
| Privacy filter | Security | `tools/security/privacy-filter.md` |
| Shannon entropy | Security | `tools/security/shannon.md` |
| Tirith | Security | `tools/security/tirith.md` |
| Encryption stack | Encryption | `tools/credentials/encryption-stack.md` |
| Multi-tenant credentials | Secrets | `tools/credentials/multi-tenant.md` |

Note: Additional tools (Tor, YubiKey, Whonix, Tails, etc.) assessed and added as needs arise.

### Webhook/API Integration Opportunities

- **SimpleX CLI WebSocket API** — primary integration point for bots
- **SMP server monitoring** — self-hosted servers expose metrics
- **XFTP server** — self-hosted file transfer servers
- **WebRTC TURN/STUN** — self-hosted relay servers for calls
- **Remote Control Protocol (XRCP)** — control CLI from desktop app (SSH tunnel + link exchange)
- **Push notifications** — optional, via Apple/Google push services (privacy trade-off)
- **Matterbridge integration** — bridge SimpleX to Matrix, Telegram, Discord, Slack, IRC, and 40+ other platforms via [matterbridge-simplex](https://github.com/UnkwUsr/matterbridge-simplex) (MIT, JavaScript). Uses SimpleX CLI WebSocket API + Matterbridge HTTP API. Docker-compose deployment. Enables unified messaging across all platforms while keeping SimpleX as the secure endpoint. Particularly valuable for bridging our existing Matrix rooms to SimpleX channels — users can choose their preferred privacy level while staying in the same conversation.

### Matterbridge-SimpleX Bridge Details

[matterbridge-simplex](https://github.com/UnkwUsr/matterbridge-simplex) is a Node.js adapter that connects SimpleX Chat to [Matterbridge](https://github.com/42wim/matterbridge) (40+ platform bridge).

**Architecture:**
```
SimpleX CLI (WebSocket :5225)
    |
matterbridge-simplex (Node.js adapter)
    |
Matterbridge API (HTTP :4242)
    |
    |--- Matrix rooms (existing aidevops integration)
    |--- Telegram groups
    |--- Discord channels
    |--- Slack workspaces
    |--- IRC channels
    |--- 40+ other platforms
```

**Key details:**
- Connects to SimpleX CLI via same WebSocket API as our bot
- Bridges both contact and group chats (configurable per chat ID)
- Docker-compose deployment with 3 containers (simplex-cli, matterbridge, node-app)
- Image previews from SimpleX forwarded to other platforms (full file support WIP)
- `/hide` prefix for SimpleX-only messages (not bridged) — useful for private comms
- Requires matterbridge >1.26.0 (maintained fork at bibanon/matterbridge)
- MIT licensed — can integrate or fork freely

**Integration with existing Matrix agent:**
- Our `matrix-bot.md` agent already handles Matrix. Matterbridge can unify SimpleX + Matrix into a single conversation flow.
- Users on Matrix see messages from SimpleX users (and vice versa) without either side needing the other's client.
- aidevops bot commands work from either side — the bot receives messages regardless of origin platform.
- Privacy gradient: users who need maximum privacy use SimpleX directly; users who prefer convenience use Matrix/Telegram/etc.

### Resolved Questions

1. **MCP Server for SimpleX?** — DECIDED: No. CLI agents serve the same purpose without context bloat. MCP adds overhead (schema, tool registration, token cost per invocation) with no capability that the bot + helper script don't already provide. The WebSocket bot IS the integration layer.
2. **Agent-to-agent protocol?** — DECIDED: Extend existing `mail-helper.sh` SQLite mailbox system. The mailbox already has message types (task_dispatch, status_report, discovery, request, broadcast), agent registration, convoy tracking, and SQLite WAL performance. Add a SimpleX (and optionally Matrix) transport adapter so the same mailbox protocol works across machines over encrypted channels. No new protocol needed.
3. **Self-hosted SMP server?** — DECIDED: Include setup guidance in simplex.md. Future: Cloudron app package and bare VPS/Proxmox setup guide as separate tasks when needed.
4. **Priority?** — DECIDED: Low priority for now. Logging all research while in mind. Queue for later implementation.

### Open Suggestions

1. **Notification bridge** — SimpleX messages could trigger aidevops alerts, and aidevops events could send SimpleX notifications.
2. **Group moderation bot** — SimpleX groups need moderation. An aidevops-powered moderation bot could use AI to detect spam/abuse.
3. **Voice-to-text pipeline** — Voice notes received via SimpleX -> transcribe -> process -> respond. Leverages existing speech-to-speech agent.
4. **Contribution workflow** — SimpleX is AGPL. Any bot framework we build should be compatible. Consider contributing useful bots upstream.
5. **Matterbridge unified messaging** — Bridge SimpleX to existing Matrix rooms (and optionally Telegram, Discord, etc.) via matterbridge-simplex. Enables privacy-gradient messaging where users choose their preferred client while staying in the same conversation.

### Inspiration from IronClaw and OpenClaw

Researched [IronClaw](https://github.com/nearai/ironclaw) (Rust, 3.4K stars, Apache-2.0/MIT) and [OpenClaw](https://github.com/openclaw/openclaw) (TypeScript, 225K stars, MIT) — both are personal AI assistants that connect to chat platforms. Key patterns relevant to our SimpleX/chat integration:

**Opsec inspiration from IronClaw:**

| Pattern | IronClaw Implementation | aidevops Adaptation |
|---------|------------------------|---------------------|
| WASM sandbox for untrusted tools | Capability-based permissions, endpoint allowlisting, resource limits | Consider for bot command execution — untrusted user commands from chat should run sandboxed |
| Credential injection at host boundary | Secrets never exposed to WASM code; injected at runtime | Already have gopass/credentials.sh — ensure bot never passes secrets to chat context |
| Leak detection | Scans requests/responses for secret exfiltration | Add to opsec agent — scan outbound messages for credential patterns before sending |
| Endpoint allowlisting | HTTP requests only to explicitly approved hosts/paths | Bot should only call approved APIs — no arbitrary URL fetching from chat commands |
| Prompt injection defense | Pattern detection, content sanitization, policy enforcement (Block/Warn/Review/Sanitize) | Chat messages are untrusted input — need injection defense before passing to AI model |
| DM pairing codes | Unknown senders get pairing code; must be approved before bot processes messages | Adopt for SimpleX bot — `aidevops simplex pairing approve <code>` |
| Per-group tool policies | Allow/deny specific tools per group | Different SimpleX groups could have different command permissions |

**Chat platform integration patterns from OpenClaw (225K stars, 14K+ commits):**

| Pattern | OpenClaw Implementation | aidevops Adaptation |
|---------|------------------------|---------------------|
| Multi-channel gateway | Single WebSocket control plane, channels connect as adapters | Our bot framework should have a channel abstraction — SimpleX, Matrix, future platforms plug in |
| Session-per-sender | Each DM/group gets isolated session with own context | Each SimpleX contact/group gets own aidevops session state |
| Mention-based activation in groups | Bot only responds when @mentioned or /commanded | SimpleX groups: bot listens for `/` commands or @mentions, ignores other messages |
| Typing indicators | Show "typing..." while AI processes | SimpleX supports typing indicators — send while processing |
| Media pipeline | Images/audio/video transcription, size caps, temp file lifecycle | Voice notes -> transcribe, images -> describe, files -> analyze |
| DM pairing flow | Unknown user -> pairing code -> admin approves -> allowlisted | Same pattern for SimpleX: unknown contact -> pairing code -> `aidevops simplex pairing approve` |
| Per-channel chunking | Long responses split per platform limits | SimpleX has no hard message limit but chunk for readability |
| Group session priming | Member roster injected into context | SimpleX group: inject member list so AI knows who's in the conversation |
| Agent-to-agent sessions | `sessions_send` for cross-session coordination | Maps to our mailbox transport — agents coordinate via mail-helper.sh over SimpleX |
| Heartbeat system | Proactive background execution for monitoring | Bot could run periodic health checks, send status updates to configured contacts |
| Routines engine | Cron schedules, event triggers, webhook handlers | Bot could support scheduled messages, event-driven notifications |
| Skills platform | Modular capabilities with install gating | Bot commands as "skills" — installable, per-group configurable |

**Key architectural insight from both projects:**

Both use a **gateway pattern** — a central control plane that channels connect to as adapters. This is exactly what our bot framework should do:

```
SimpleX CLI (WebSocket adapter)
    |
aidevops Chat Gateway (central control plane)
    |--- Session manager (per-sender/group isolation)
    |--- Command router (slash commands)
    |--- Tool executor (sandboxed)
    |--- Media pipeline (voice/image/file)
    |--- Mailbox bridge (inter-agent comms)
    |
Matrix adapter (future, via existing matrix-bot.md)
    |
Other adapters (future, via Matterbridge or native)
```

This means the bot framework (t1327.4) should be designed as a **channel-agnostic gateway** with SimpleX as the first adapter, not a SimpleX-specific monolith. Matrix and other channels plug in later without rewriting the core.

**Security model for chat-connected AI (for opsec agent t1327.6):**

Both projects treat inbound DMs as **untrusted input** — this is critical for our opsec guidance:

1. **DM pairing by default** — unknown senders must be approved before bot processes messages
2. **Prompt injection defense** — chat messages pass through sanitization before reaching AI
3. **Tool sandboxing** — commands from chat run in restricted environment (WASM in IronClaw, Docker in OpenClaw)
4. **Credential isolation** — secrets never exposed to chat context or tool output
5. **Leak detection** — scan outbound messages for credential patterns
6. **Per-group tool policies** — different groups get different command permissions
7. **Exec approvals** — dangerous commands require explicit approval before execution
8. **Allowlist/blocklist** — per-contact and per-group access control

References:
- https://github.com/nearai/ironclaw (Rust, Apache-2.0/MIT, 3.4K stars)
- https://github.com/openclaw/openclaw (TypeScript, MIT, 225K stars)
- https://github.com/nearai/ironclaw/blob/main/FEATURE_PARITY.md (detailed feature comparison)
