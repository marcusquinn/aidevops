---
mode: subagent
---
# t1328: Matterbridge Agent for Multi-Platform Chat Bridging

## Origin

- **Created:** 2026-02-25
- **Session:** claude-code:simplex-agent-planning
- **Created by:** marcusquinn (human)
- **Parent task:** Related to t1327 (SimpleX Chat integration)
- **Conversation context:** While planning SimpleX integration, identified that Matterbridge is a distinct tool deserving its own agent — it bridges 40+ chat platforms and is the mechanism for connecting SimpleX to Matrix and other platforms.

## What

A Matterbridge subagent and helper script for aidevops:

1. **Subagent doc** (`.agents/services/communications/matterbridge.md`) — setup, configuration, platform-specific gateway configs, Docker deployment, security guidance, and cross-reference to opsec agent for platform trust assessment
2. **Helper script** (`matterbridge-helper.sh`) — CLI wrapper for install, configure, start/stop, status, add/remove gateways, test bridges
3. **Security cross-reference** — the agent itself documents setup; platform security/privacy assessments live in the opsec agent (`.agents/tools/security/opsec.md`, t1327.6) which covers: which platforms are E2E encrypted, which gather metadata, which may train on chat content, and recommends secure apps we already support (SimpleX, Matrix)

## Why

Matterbridge (7.4K stars, Apache-2.0, Go) is the de facto standard for bridging chat platforms. It natively supports 20+ platforms (Matrix, Discord, Telegram, Slack, IRC, WhatsApp, XMPP, MS Teams, etc.) and has a REST API for 3rd-party adapters (including matterbridge-simplex for SimpleX).

Without a dedicated agent, every time we need to bridge platforms we'd be re-researching config syntax, gateway setup, and Docker deployment. The agent captures this once.

The security angle is important: bridging inherently sends messages to platforms with different privacy properties. Users need clear guidance on what they're exposing when they bridge SimpleX (zero-knowledge) to Telegram (phone number required, server-side storage) or Discord (no E2E encryption, trains on data). This guidance lives in the opsec agent and is cross-referenced from here.

## How (Approach)

### Architecture

```
Platform A (e.g., SimpleX via matterbridge-simplex adapter)
    |
Matterbridge (Go binary or Docker container)
    |--- Gateway 1: SimpleX <-> Matrix
    |--- Gateway 2: Matrix <-> Telegram
    |--- Gateway N: any <-> any
    |
Platform B, C, D... (Matrix, Telegram, Discord, Slack, IRC, etc.)
```

### Key Technical Details

**Natively supported platforms (20+):**
Discord, Gitter, IRC, Keybase, Matrix, Mattermost, MS Teams, Mumble, Nextcloud Talk, Rocket.Chat, Slack, SSH-Chat, Telegram, Twitch, VK, WhatsApp, XMPP, Zulip

**3rd-party via API:**
SimpleX (matterbridge-simplex), Delta Chat, Minecraft

**Configuration:** Single `matterbridge.toml` file defining:
- Platform credentials (tokens, servers, logins)
- Gateways (which channels on which platforms are bridged)
- Message formatting (`RemoteNickFormat`, `PrefixMessagesWithNick`)
- Features per gateway (edits, deletes, attachments, threading)

**Deployment options:**
- Binary (Go, single file, ~50MB)
- Docker (`42wim/matterbridge`)
- Snap package
- Systemd service

**Features:**
- Message edits and deletes (where supported)
- Attachment/file handling
- Username and avatar spoofing (messages appear native)
- Private group support
- REST API for custom integrations
- Threading preservation (where supported)

### Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `.agents/services/communications/matterbridge.md` | Create | Subagent doc |
| `.agents/scripts/matterbridge-helper.sh` | Create | CLI helper |
| `subagent-index.toon` | Update | Register subagent |
| `.agents/AGENTS.md` | Update | Domain index |
| `.agents/tools/security/opsec.md` | Update (t1327.6) | Add platform trust matrix |

### Reference Patterns

- Follow `services/communications/matrix-bot.md` for comms agent structure
- Follow `scripts/simplex-helper.sh` (t1327.3) for helper script pattern

## Acceptance Criteria

- [ ] Subagent doc `.agents/services/communications/matterbridge.md` covers: installation, `matterbridge.toml` configuration, gateway setup for key platforms (Matrix, SimpleX, Telegram, Discord, IRC), Docker deployment, REST API, troubleshooting
  ```yaml
  verify:
    method: codebase
    pattern: "matterbridge"
    path: ".agents/services/communications/matterbridge.md"
  ```
- [ ] Helper script `matterbridge-helper.sh` provides: install, init, start, stop, status, gateway-add, gateway-rm, test subcommands
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/matterbridge-helper.sh && grep -c 'cmd_' .agents/scripts/matterbridge-helper.sh | awk '{exit ($1 >= 5) ? 0 : 1}'"
  ```
- [ ] Security guidance cross-references opsec agent — does NOT duplicate platform assessments, instead links to `tools/security/opsec.md` for platform trust matrix
  ```yaml
  verify:
    method: codebase
    pattern: "opsec|security/opsec"
    path: ".agents/services/communications/matterbridge.md"
  ```
- [ ] Opsec agent (t1327.6) includes platform trust matrix covering: E2E encryption status, metadata collection, data training policies, phone number requirements, recommended vs cautioned platforms
  ```yaml
  verify:
    method: codebase
    pattern: "platform.*trust|metadata.*collection|E2E.*encrypt"
    path: ".agents/tools/security/opsec.md"
  ```
- [ ] Subagent index and AGENTS.md updated
  ```yaml
  verify:
    method: codebase
    pattern: "matterbridge"
    path: "subagent-index.toon"
  ```
- [ ] Lint clean (`shellcheck` for scripts, markdown lint for docs)

## Context & Decisions

- **Separate agent from SimpleX**: Matterbridge is a general-purpose bridge tool, not SimpleX-specific. It deserves its own agent for reuse across any bridging need.
- **Security warnings in opsec, not here**: The Matterbridge agent covers how to bridge; the opsec agent covers whether you should bridge to a given platform and what you're exposing. Avoids duplication and keeps security guidance centralized.
- **Platform trust matrix in opsec**: Categorize platforms as: secure (E2E, no metadata — SimpleX, Matrix), cautioned (metadata collection, phone required — Telegram, WhatsApp, Signal), and warned (no E2E, may train on data — Discord, Slack, MS Teams, IRC). Recommend secure apps we already support.
- **Docker-first deployment**: Matterbridge + matterbridge-simplex is easiest via Docker-compose (3 containers). Document both Docker and binary options.
- **REST API for future extensibility**: Matterbridge's API allows custom integrations — could be used for aidevops event notifications, alert routing, etc.

## Relevant Files

- `.agents/services/communications/simplex.md` — SimpleX agent (t1327.2), references Matterbridge for bridging
- `.agents/services/communications/matrix-bot.md` — existing Matrix agent
- `.agents/tools/security/opsec.md` — opsec agent (t1327.6), platform trust matrix lives here
- `subagent-index.toon` — registration

## Dependencies

- **Blocked by:** Nothing — can be built independently
- **Related to:** t1327 (SimpleX integration references Matterbridge for bridging)
- **External:** Matterbridge binary or Docker image, platform API tokens for each bridged service

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Matterbridge wiki, config examples, API docs |
| Subagent doc | 2h | Installation, config, gateways, Docker, API, troubleshooting |
| Helper script | 2h | CLI wrapper with subcommands |
| Index/AGENTS.md updates | 15m | Registration |
| Testing | 1h | Config validation, gateway test |
| **Total** | **~6h** | (ai:4.5h test:1h read:30m) |
