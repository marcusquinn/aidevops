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

- **Purpose**: Personal AI assistant running locally or on a VPS, accessible via messaging channels
- **Install**: `curl -fsSL https://openclaw.ai/install.sh | bash && openclaw onboard --install-daemon`
- **Runtime**: Node.js >= 22
- **Docs**: https://docs.openclaw.ai
- **Repo**: https://github.com/openclaw/openclaw
- **Gateway**: ws://127.0.0.1:18789 (local control plane)
- **Security audit**: `openclaw security audit --deep`

**Supported Channels**: WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Microsoft Teams, WebChat, BlueBubbles, Matrix, Google Chat, Mattermost, LINE, Zalo

**Key Features**:

- Multi-channel inbox (respond from any messaging platform)
- Voice Wake + Talk Mode (macOS/iOS/Android)
- Live Canvas (agent-driven visual workspace)
- Skills system (similar to aidevops agents)
- Browser control, cron jobs, webhooks
- Agent sandboxing (Docker-based tool isolation)
- Multi-agent routing (different agents per channel/context)

<!-- AI-CONTEXT-END -->

## Deployment Tiers

OpenClaw can run in three configurations, each suited to different needs:

### Tier 1: Native Local (Simplest)

Run directly on your machine. Best for personal use, development, and getting started.

```bash
# Install OpenClaw
curl -fsSL https://openclaw.ai/install.sh | bash

# Run onboarding wizard (installs daemon)
openclaw onboard --install-daemon

# Verify
openclaw doctor
```

**Pros**: Fastest setup, no container overhead, direct filesystem access.
**Cons**: Only available when your machine is on, no isolation.

### Tier 2: OrbStack Container (Isolated)

Run in a Docker container via OrbStack on macOS. Best for isolation, easy reset, and testing.

```bash
# Ensure OrbStack is running (aidevops installs it)
orb status

# Clone and run via Docker
git clone https://github.com/openclaw/openclaw.git
cd openclaw
./docker-setup.sh
```

The setup script builds the image, runs onboarding, generates a gateway token, and starts via Docker Compose. Config and workspace are bind-mounted from `~/.openclaw/`.

**Pros**: Isolated from host, reproducible, easy to reset.
**Cons**: Slightly more complex setup, container overhead.

See `@orbstack` for OrbStack management and `tools/containers/orbstack.md` for details.

### Tier 3: Remote VPS (Always-On)

Run on a Hetzner or Hostinger VPS with Tailscale for secure access. Best for always-on availability from any device.

```bash
# 1. Provision a VPS via aidevops (use @hetzner or @hostinger)
#    Minimum: CX22 (2 vCPU, 4GB RAM) or equivalent

# 2. Install Tailscale on both local machine and VPS
#    See @tailscale for setup

# 3. SSH into VPS via Tailscale
ssh user@<tailscale-hostname>

# 4. Install OpenClaw on VPS
curl -fsSL https://openclaw.ai/install.sh | bash
openclaw onboard --install-daemon

# 5. Configure Tailscale Serve for secure HTTPS access
# In ~/.openclaw/openclaw.json:
```

```json5
{
  gateway: {
    bind: "loopback",
    tailscale: { mode: "serve" },
    auth: { mode: "token", token: "your-long-random-token" },
  },
}
```

**Pros**: Always available, accessible from any device, survives laptop sleep/shutdown.
**Cons**: Monthly VPS cost, requires Tailscale setup.

See `@tailscale` for Tailscale configuration and `services/networking/tailscale.md` for details.

### Deployment Decision Tree

```text
Do you need AI accessible 24/7 from any device?
  YES -> Do you have a VPS (Hetzner/Hostinger)?
    YES -> Tier 3: Remote VPS + Tailscale
    NO  -> Provision one via @hetzner, then Tier 3
  NO  -> Do you want isolation from your host system?
    YES -> Tier 2: OrbStack Container
    NO  -> Tier 1: Native Local
```

## Installation

### Quick Install (Recommended)

```bash
# macOS/Linux
curl -fsSL https://openclaw.ai/install.sh | bash

# Run onboarding wizard (installs daemon)
openclaw onboard --install-daemon
```

The wizard walks through:

1. Gateway setup and auth token generation
2. Model provider configuration
3. Workspace configuration
4. Channel connections (WhatsApp, Telegram, etc.)

### From Source (Development)

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw

pnpm install
pnpm ui:build
pnpm build

pnpm openclaw onboard --install-daemon

# Dev loop (auto-reload)
pnpm gateway:watch
```

## Architecture

```text
WhatsApp / Telegram / Slack / Discord / Signal / iMessage / Teams / WebChat
               |
               v
+-------------------------------+
|           Gateway             |
|       (control plane)         |
|     ws://127.0.0.1:18789      |
+---------------+---------------+
               |
               +-- Agent runtime (RPC)
               +-- CLI (openclaw ...)
               +-- Control UI / Dashboard
               +-- macOS app
               +-- iOS / Android nodes
```

## Configuration

Minimal config at `~/.openclaw/openclaw.json`:

```json5
{
  agent: {
    model: "anthropic/claude-opus-4-6"
  }
}
```

Full configuration reference: https://docs.openclaw.ai/gateway/configuration

## Channel Setup

Each channel has its own security model. Always configure allowlists before connecting.

### WhatsApp (QR Pairing)

```bash
openclaw channels login  # Scan QR code with WhatsApp
```

Default DM policy is `pairing` -- unknown senders get a pairing code you must approve:

```bash
openclaw pairing list whatsapp
openclaw pairing approve whatsapp <code>
```

### Telegram (Bot Token)

1. Create a bot via @BotFather on Telegram
2. Configure:

```json5
{
  channels: {
    telegram: {
      botToken: "123456:ABCDEF"  // or set TELEGRAM_BOT_TOKEN env var
    }
  }
}
```

### Discord (Bot Token)

1. Create application at https://discord.com/developers/applications
2. Create bot, copy token
3. Configure:

```json5
{
  channels: {
    discord: {
      token: "your-bot-token"  // or set DISCORD_BOT_TOKEN env var
    }
  }
}
```

### Slack (App Tokens)

Set `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN` environment variables.

### Signal (signal-cli)

Privacy-focused channel. Requires `signal-cli` installed separately.

### iMessage (BlueBubbles)

Recommended: Use BlueBubbles macOS server for full iMessage support (edit, unsend, effects, reactions, group management).

## Security

**Security is the most important part of OpenClaw setup.** An AI with shell access connected to messaging channels is a significant attack surface.

### Core Principle: Access Control Before Intelligence

1. **Identity first**: Decide who can talk to the bot (DM pairing / allowlists)
2. **Scope next**: Decide where the bot can act (tool policy, sandboxing)
3. **Model last**: Assume the model can be manipulated; limit blast radius

### Security Audit

Run regularly, especially after config changes:

```bash
openclaw security audit          # Quick check
openclaw security audit --deep   # Full check with live Gateway probe
openclaw security audit --fix    # Auto-fix common issues
```

The audit checks: inbound access policies, tool blast radius, network exposure, browser control, disk permissions, plugins, and model hygiene.

### Secure Baseline Config

```json5
{
  gateway: {
    mode: "local",
    bind: "loopback",
    port: 18789,
    auth: { mode: "token", token: "your-long-random-token" },
  },
  channels: {
    whatsapp: {
      dmPolicy: "pairing",
      groups: { "*": { requireMention: true } },
    },
  },
  discovery: {
    mdns: { mode: "minimal" },  // Don't broadcast sensitive info
  },
}
```

### DM Access Model

| Policy | Behavior | Use Case |
|--------|----------|----------|
| `pairing` (default) | Unknown senders get a code, must be approved | Personal use |
| `allowlist` | Only pre-approved senders, no pairing handshake | Controlled access |
| `open` | Anyone can DM (requires `allowFrom: ["*"]`) | Public bots only |
| `disabled` | Ignore all inbound DMs | Channel-specific disable |

### Group Security

Always require mention in groups to prevent the bot responding to every message:

```json5
{
  channels: {
    whatsapp: {
      groups: { "*": { requireMention: true } },
      groupPolicy: "allowlist",
    },
  },
}
```

### Session Isolation (Multi-User)

If multiple people can DM the bot, isolate sessions to prevent cross-user context leakage:

```json5
{
  session: { dmScope: "per-channel-peer" },
}
```

### Prompt Injection Awareness

Even with locked-down DMs, prompt injection can happen via any untrusted content the bot reads (web pages, emails, attachments). Mitigations:

- Use a read-only reader agent for untrusted content, pass summaries to main agent
- Keep `web_search`/`web_fetch`/`browser` off for tool-enabled agents unless needed
- Enable sandboxing for agents that touch untrusted input
- Keep secrets out of prompts; use env/config on the gateway host

### Sandboxing

Enable Docker-based tool isolation for non-main sessions:

```json5
{
  agents: {
    defaults: {
      sandbox: {
        mode: "non-main",
        scope: "agent",
        workspaceAccess: "none",
      },
    },
  },
}
```

### File Permissions

```bash
chmod 700 ~/.openclaw
chmod 600 ~/.openclaw/openclaw.json
# The security audit checks and can fix these
openclaw security audit --fix
```

## CLI Commands

```bash
# Gateway management
openclaw gateway --port 18789 --verbose
openclaw gateway status
openclaw dashboard                    # Open Control UI

# Messaging
openclaw message send --target +15555550123 --message "Hello"

# Agent interaction
openclaw agent --message "Ship checklist" --thinking high

# Health and security
openclaw doctor
openclaw security audit --deep

# Channel management
openclaw channels login
openclaw channels list

# Pairing (DM security)
openclaw pairing list <channel>
openclaw pairing approve <channel> <code>

# Session management
openclaw sessions list
openclaw sessions history <sessionId>
```

## Chat Commands

Send these in any connected channel:

| Command | Purpose |
|---------|---------|
| `/status` | Session status (model, tokens, cost) |
| `/new` or `/reset` | Reset the session |
| `/compact` | Compact session context |
| `/think <level>` | Set thinking level (off/minimal/low/medium/high/xhigh) |
| `/verbose on/off` | Toggle verbose mode |
| `/usage off/tokens/full` | Per-response usage footer |
| `/restart` | Restart gateway (owner-only) |

## Skills (Agent Workspace)

OpenClaw uses a skills system similar to aidevops agents:

- Workspace root: `~/.openclaw/workspace` (configurable)
- Injected prompts: `AGENTS.md`, `SOUL.md`, `TOOLS.md`
- Skills location: `~/.openclaw/workspace/skills/<skill>/SKILL.md`

## Integration with aidevops

OpenClaw and aidevops are complementary tools with different strengths:

### When to Use Each

| Scenario | Use | Why |
|----------|-----|-----|
| Writing code, debugging, PRs | **aidevops** | Full IDE integration, file editing, git workflow |
| Quick question from your phone | **OpenClaw** | WhatsApp/Telegram, always available |
| Server monitoring alerts | **OpenClaw** | Cron jobs + messaging channels |
| Complex multi-file refactor | **aidevops** | Edit/Write tools, worktrees, preflight |
| Voice interaction while driving | **OpenClaw** | Talk Mode, Voice Wake |
| SEO research and analysis | **aidevops** | DataForSEO integration, structured output |
| Client communication bot | **OpenClaw** | Multi-channel, pairing, session isolation |
| CI/CD and deployment | **aidevops** | GitHub Actions, Coolify, release workflow |

### Cross-Integration

aidevops infrastructure agents can manage the server OpenClaw runs on:

- `@hetzner` -- Provision and manage the VPS running OpenClaw
- `@cloudflare` -- DNS for custom domain pointing to OpenClaw gateway
- `@tailscale` -- Secure mesh network between your devices and the gateway
- `@orbstack` -- Local Docker container management for OpenClaw

OpenClaw can trigger aidevops workflows via messaging:

- Message your bot "deploy the latest release" and it can run deployment scripts
- Set up cron jobs in OpenClaw to monitor server health via aidevops scripts
- Use OpenClaw webhooks to trigger aidevops CI/CD pipelines

### Recommended Setup

1. Install OpenClaw: `curl -fsSL https://openclaw.ai/install.sh | bash`
2. Run onboarding: `openclaw onboard --install-daemon`
3. Connect your preferred channel (WhatsApp recommended for mobile)
4. Run security audit: `openclaw security audit --fix`
5. Configure workspace to use aidevops agents:

```json5
{
  agents: {
    defaults: {
      workspace: "~/Git/your-project"
    }
  }
}
```

## Tailscale Integration

For remote gateway access, Tailscale provides secure networking without port forwarding:

### Tailscale Serve (Tailnet-Only)

```json5
{
  gateway: {
    bind: "loopback",
    tailscale: { mode: "serve" },
  },
}
```

Access via `https://<magicdns>/` from any device on your tailnet.

### Tailscale Funnel (Public, Use with Caution)

```json5
{
  gateway: {
    bind: "loopback",
    tailscale: { mode: "funnel" },
    auth: { mode: "password", password: "${OPENCLAW_GATEWAY_PASSWORD}" },
  },
}
```

Funnel requires auth mode `password`. Prefer `OPENCLAW_GATEWAY_PASSWORD` env var over config file.

### Tailscale Identity Headers

When using Serve, OpenClaw can authenticate via Tailscale identity headers (`tailscale-user-login`) without requiring a separate token. Set `gateway.auth.allowTailscale: true` (default for Serve).

See `@tailscale` and `services/networking/tailscale.md` for full Tailscale setup.

## Companion Apps (Optional)

### macOS App

- Menu bar control for Gateway
- Voice Wake + push-to-talk
- WebChat + debug tools

### iOS/Android Nodes

- Canvas surface
- Voice trigger forwarding
- Camera/screen capture

## Troubleshooting

```bash
# Check gateway health
openclaw doctor

# View logs
openclaw gateway --verbose

# Security check
openclaw security audit --deep

# Full status (secrets redacted)
openclaw status --all

# Reset credentials (last resort)
rm -rf ~/.openclaw/credentials
openclaw channels login
```

## Resources

- **Website**: https://openclaw.ai
- **Docs**: https://docs.openclaw.ai
- **Getting Started**: https://docs.openclaw.ai/start/getting-started
- **Configuration**: https://docs.openclaw.ai/gateway/configuration
- **Security**: https://docs.openclaw.ai/gateway/security
- **Tailscale**: https://docs.openclaw.ai/gateway/tailscale
- **Docker**: https://docs.openclaw.ai/install/docker
- **Discord**: https://discord.gg/openclaw
- **GitHub**: https://github.com/openclaw/openclaw
