---
description: OpenClaw - Personal AI assistant for messaging channels (WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Teams)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# OpenClaw - Personal AI Assistant

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Install**: `curl -fsSL https://openclaw.ai/install.sh | bash && openclaw onboard --install-daemon`
- **Runtime**: Node.js >= 22
- **Docs**: https://docs.openclaw.ai | **Repo**: https://github.com/openclaw/openclaw
- **Gateway**: ws://127.0.0.1:18789 | **Security audit**: `openclaw security audit --deep`

**Channels**: WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Microsoft Teams, WebChat, BlueBubbles, Matrix, Google Chat, Mattermost, LINE, Zalo

**Key Features**: Multi-channel inbox, Voice Wake + Talk Mode (macOS/iOS/Android), Live Canvas, Skills system, Browser control, cron jobs, webhooks, Agent sandboxing (Docker), Multi-agent routing

<!-- AI-CONTEXT-END -->

## Deployment Tiers

```text
Need AI 24/7 from any device?
  YES → Have a VPS (Hetzner/Hostinger)?
    YES → Tier 3: Remote VPS + Tailscale
    NO  → Provision one via @hetzner, then Tier 3
  NO  → Want isolation from host?
    YES → Tier 2: OrbStack Container
    NO  → Tier 1: Native Local
```

**Tier 1 — Native Local** (simplest, fastest setup, no isolation):
```bash
curl -fsSL https://openclaw.ai/install.sh | bash
openclaw onboard --install-daemon
openclaw doctor
```

**Tier 2 — OrbStack Container** (isolated, easy reset):
```bash
git clone https://github.com/openclaw/openclaw.git && cd openclaw
./docker-setup.sh  # builds image, runs onboarding, starts via Docker Compose
```
Config and workspace bind-mounted from `~/.openclaw/`. See `tools/containers/orbstack.md`.

**Tier 3 — Remote VPS** (always-on, any device):
```bash
# 1. Provision VPS (min CX22: 2 vCPU, 4GB RAM) via @hetzner or @hostinger
# 2. Install Tailscale on both machines (see @tailscale)
# 3. SSH into VPS and install OpenClaw
curl -fsSL https://openclaw.ai/install.sh | bash && openclaw onboard --install-daemon
```
```json5
// ~/.openclaw/openclaw.json — Tailscale Serve config
{
  gateway: {
    bind: "loopback",
    tailscale: { mode: "serve" },
    auth: { mode: "token", token: "your-long-random-token" },
  },
}
```

## From Source (Development)

```bash
git clone https://github.com/openclaw/openclaw.git && cd openclaw
pnpm install && pnpm ui:build && pnpm build
pnpm openclaw onboard --install-daemon
pnpm gateway:watch  # dev loop with auto-reload
```

## Architecture

```text
WhatsApp / Telegram / Slack / Discord / Signal / iMessage / Teams / WebChat
                |
                v
+-------------------------------+
|           Gateway             |  ws://127.0.0.1:18789
+---------------+---------------+
                +-- Agent runtime (RPC)
                +-- CLI (openclaw ...)
                +-- Control UI / Dashboard
                +-- macOS app / iOS / Android nodes
```

Minimal config at `~/.openclaw/openclaw.json`:
```json5
{ agent: { model: "anthropic/claude-opus-4-6" } }
```
Full reference: https://docs.openclaw.ai/gateway/configuration

## Channel Setup

Always configure allowlists before connecting.

**WhatsApp** (QR pairing):
```bash
openclaw channels login  # scan QR code
openclaw pairing list whatsapp
openclaw pairing approve whatsapp <code>
```

**Telegram** — create bot via @BotFather, then:
```json5
{ channels: { telegram: { botToken: "123456:ABCDEF" } } }
```

**Discord** — create app at https://discord.com/developers/applications, then:
```json5
{ channels: { discord: { token: "your-bot-token" } } }
```

**Slack** — set `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN` env vars.

**Signal** — privacy-focused; requires `signal-cli` installed separately.

**iMessage** — use BlueBubbles macOS server for full support (edit, unsend, effects, reactions, group management).

## Security

**Security is the most important part of OpenClaw setup.** An AI with shell access connected to messaging channels is a significant attack surface.

**Principle: Access Control Before Intelligence**
1. Identity first — who can talk to the bot (DM pairing / allowlists)
2. Scope next — where the bot can act (tool policy, sandboxing)
3. Model last — assume the model can be manipulated; limit blast radius

```bash
openclaw security audit          # quick check
openclaw security audit --deep   # full check with live Gateway probe
openclaw security audit --fix    # auto-fix common issues
```

**Secure baseline config:**
```json5
{
  gateway: {
    mode: "local", bind: "loopback", port: 18789,
    auth: { mode: "token", token: "your-long-random-token" },
  },
  channels: {
    whatsapp: {
      dmPolicy: "pairing",
      groups: { "*": { requireMention: true } },
    },
  },
  discovery: { mdns: { mode: "minimal" } },
}
```

**DM access policies:**

| Policy | Behavior | Use Case |
|--------|----------|----------|
| `pairing` (default) | Unknown senders get a code, must be approved | Personal use |
| `allowlist` | Only pre-approved senders | Controlled access |
| `open` | Anyone can DM (requires `allowFrom: ["*"]`) | Public bots only |
| `disabled` | Ignore all inbound DMs | Channel-specific disable |

**Group security** — always require mention:
```json5
{ channels: { whatsapp: { groups: { "*": { requireMention: true } }, groupPolicy: "allowlist" } } }
```

**Session isolation** (multi-user, prevents cross-user context leakage):
```json5
{ session: { dmScope: "per-channel-peer" } }
```

**Prompt injection** — even with locked-down DMs, injection can happen via untrusted content (web pages, emails, attachments). Mitigations: use a read-only reader agent for untrusted content; keep `web_search`/`browser` off unless needed; enable sandboxing for agents touching untrusted input; keep secrets out of prompts.

**Sandboxing:**
```json5
{ agents: { defaults: { sandbox: { mode: "non-main", scope: "agent", workspaceAccess: "none" } } } }
```

**File permissions:**
```bash
chmod 700 ~/.openclaw && chmod 600 ~/.openclaw/openclaw.json
```

## CLI Commands

```bash
openclaw gateway --port 18789 --verbose  # start gateway
openclaw gateway status
openclaw dashboard                        # open Control UI
openclaw message send --target +15555550123 --message "Hello"
openclaw agent --message "Ship checklist" --thinking high
openclaw doctor
openclaw security audit --deep
openclaw channels login && openclaw channels list
openclaw pairing list <channel> && openclaw pairing approve <channel> <code>
openclaw sessions list && openclaw sessions history <sessionId>
```

## Chat Commands

| Command | Purpose |
|---------|---------|
| `/status` | Session status (model, tokens, cost) |
| `/new` or `/reset` | Reset session |
| `/compact` | Compact context |
| `/think <level>` | Set thinking level (off/minimal/low/medium/high/xhigh) |
| `/verbose on/off` | Toggle verbose mode |
| `/usage off/tokens/full` | Per-response usage footer |
| `/restart` | Restart gateway (owner-only) |

## Skills

Workspace root: `~/.openclaw/workspace`. Injected prompts: `AGENTS.md`, `SOUL.md`, `TOOLS.md`. Skills: `~/.openclaw/workspace/skills/<skill>/SKILL.md`.

## Integration with aidevops

| Scenario | Use | Why |
|----------|-----|-----|
| Writing code, debugging, PRs | **aidevops** | Full IDE integration, file editing, git workflow |
| Quick question from phone | **OpenClaw** | WhatsApp/Telegram, always available |
| Server monitoring alerts | **OpenClaw** | Cron jobs + messaging channels |
| Complex multi-file refactor | **aidevops** | Edit/Write tools, worktrees, preflight |
| Voice interaction while driving | **OpenClaw** | Talk Mode, Voice Wake |
| SEO research and analysis | **aidevops** | DataForSEO integration, structured output |
| Client communication bot | **OpenClaw** | Multi-channel, pairing, session isolation |
| CI/CD and deployment | **aidevops** | GitHub Actions, Coolify, release workflow |

**Cross-integration:** aidevops agents manage the server OpenClaw runs on (`@hetzner`, `@cloudflare`, `@tailscale`, `@orbstack`). OpenClaw can trigger aidevops workflows via messaging — e.g., "deploy the latest release" runs deployment scripts; cron jobs monitor server health via aidevops scripts; webhooks trigger CI/CD pipelines.

## Tailscale Integration

```json5
// Tailnet-only (recommended)
{ gateway: { bind: "loopback", tailscale: { mode: "serve" } } }
// Access via https://<magicdns>/ from any tailnet device

// Public funnel (use with caution — requires password auth)
{ gateway: { bind: "loopback", tailscale: { mode: "funnel" }, auth: { mode: "password", password: "${OPENCLAW_GATEWAY_PASSWORD}" } } }
```

When using Serve, set `gateway.auth.allowTailscale: true` (default) to authenticate via Tailscale identity headers without a separate token. See `services/networking/tailscale.md`.

## Companion Apps

- **macOS**: menu bar control, Voice Wake, WebChat + debug tools
- **iOS/Android**: Canvas surface, voice trigger forwarding, camera/screen capture

## Troubleshooting

```bash
openclaw doctor                  # gateway health
openclaw gateway --verbose       # view logs
openclaw security audit --deep   # security check
openclaw status --all            # full status (secrets redacted)
rm -rf ~/.openclaw/credentials && openclaw channels login  # reset credentials (last resort)
```

## Resources

- https://openclaw.ai | https://docs.openclaw.ai
- [Getting Started](https://docs.openclaw.ai/start/getting-started) | [Configuration](https://docs.openclaw.ai/gateway/configuration)
- [Security](https://docs.openclaw.ai/gateway/security) | [Tailscale](https://docs.openclaw.ai/gateway/tailscale) | [Docker](https://docs.openclaw.ai/install/docker)
- [Discord](https://discord.gg/openclaw) | [GitHub](https://github.com/openclaw/openclaw)
