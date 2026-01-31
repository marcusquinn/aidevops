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

- **Purpose**: Personal AI assistant running locally, accessible via messaging channels
- **Install**: `npm install -g openclaw@latest && openclaw onboard --install-daemon`
- **Runtime**: Node.js >= 22
- **Docs**: https://docs.openclaw.ai
- **Repo**: https://github.com/openclaw/openclaw
- **Gateway**: ws://127.0.0.1:18789 (local control plane)

**Supported Channels**: WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Microsoft Teams, WebChat, BlueBubbles, Matrix, Google Chat, Zalo

**Key Features**:
- Multi-channel inbox (respond from any messaging platform)
- Voice Wake + Talk Mode (macOS/iOS/Android)
- Live Canvas (agent-driven visual workspace)
- Skills system (similar to aidevops agents)
- Browser control, cron jobs, webhooks

<!-- AI-CONTEXT-END -->

## Installation

### Quick Install (Recommended)

```bash
# Requires Node.js >= 22
npm install -g openclaw@latest
# or: pnpm add -g openclaw@latest

# Run onboarding wizard (installs daemon)
openclaw onboard --install-daemon
```

The wizard walks through:
1. Gateway setup
2. Workspace configuration
3. Channel connections (WhatsApp, Telegram, etc.)
4. Skills installation

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
               +-- Pi agent (RPC)
               +-- CLI (openclaw ...)
               +-- WebChat UI
               +-- macOS app
               +-- iOS / Android nodes
```

## Configuration

Minimal config at `~/.openclaw/openclaw.json`:

```json5
{
  agent: {
    model: "anthropic/claude-opus-4-5"
  }
}
```

Full configuration reference: https://docs.openclaw.ai/gateway/configuration

### Channel Setup

#### WhatsApp

```bash
openclaw channels login  # Scan QR code
```

Configure allowlist in `~/.openclaw/openclaw.json`:

```json5
{
  channels: {
    whatsapp: {
      allowFrom: ["+1234567890"]
    }
  }
}
```

#### Telegram

```json5
{
  channels: {
    telegram: {
      botToken: "123456:ABCDEF"
    }
  }
}
```

Or set `TELEGRAM_BOT_TOKEN` environment variable.

#### Slack

Set `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN` environment variables.

#### Discord

```json5
{
  channels: {
    discord: {
      token: "your-bot-token"
    }
  }
}
```

Or set `DISCORD_BOT_TOKEN` environment variable.

## CLI Commands

```bash
# Start gateway
openclaw gateway --port 18789 --verbose

# Send a message
openclaw message send --to +1234567890 --message "Hello from OpenClaw"

# Talk to the assistant
openclaw agent --message "Ship checklist" --thinking high

# Health check
openclaw doctor

# Manage channels
openclaw channels login
openclaw channels list

# Manage pairings (DM security)
openclaw pairing approve <channel> <code>
openclaw pairing list
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

## Security

Default DM policy is `pairing` - unknown senders receive a pairing code:

```bash
# Approve a sender
openclaw pairing approve telegram ABC123
```

For open DMs (not recommended), set:

```json5
{
  channels: {
    telegram: {
      dm: {
        policy: "open",
        allowFrom: ["*"]
      }
    }
  }
}
```

Run `openclaw doctor` to check for risky configurations.

## Skills (Agent Workspace)

OpenClaw uses a skills system similar to aidevops agents:

- Workspace root: `~/.openclaw/workspace` (configurable)
- Injected prompts: `AGENTS.md`, `SOUL.md`, `TOOLS.md`
- Skills location: `~/.openclaw/workspace/skills/<skill>/SKILL.md`

## Integration with aidevops

OpenClaw complements aidevops by providing:

1. **Mobile access**: Interact with AI from WhatsApp/Telegram on your phone
2. **Always-on assistant**: Gateway runs as a daemon, always available
3. **Voice interface**: Talk Mode for hands-free interaction
4. **Multi-channel routing**: Different channels can route to different agents

### Recommended Setup

1. Install OpenClaw: `npm install -g openclaw@latest`
2. Run onboarding: `openclaw onboard --install-daemon`
3. Connect your preferred channel (WhatsApp recommended for mobile)
4. Configure workspace to use aidevops agents:

```json5
{
  agents: {
    defaults: {
      workspace: "~/Git/your-project"
    }
  }
}
```

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

# Reset credentials
rm -rf ~/.openclaw/credentials
openclaw channels login
```

## Resources

- **Website**: https://openclaw.ai
- **Docs**: https://docs.openclaw.ai
- **Getting Started**: https://docs.openclaw.ai/start/getting-started
- **Configuration**: https://docs.openclaw.ai/gateway/configuration
- **Security**: https://docs.openclaw.ai/gateway/security
- **Discord**: https://discord.gg/openclaw
- **GitHub**: https://github.com/openclaw/openclaw
