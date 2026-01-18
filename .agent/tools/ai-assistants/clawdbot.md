---
description: Clawdbot - Personal AI assistant for messaging channels (WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Teams)
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

# Clawdbot - Personal AI Assistant

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Personal AI assistant running locally, accessible via messaging channels
- **Install**: `npm install -g clawdbot@latest && clawdbot onboard --install-daemon`
- **Runtime**: Node.js >= 22
- **Docs**: https://docs.clawd.bot
- **Repo**: https://github.com/clawdbot/clawdbot
- **Gateway**: ws://127.0.0.1:18789 (local control plane)

**Supported Channels**: WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Microsoft Teams, WebChat

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
npm install -g clawdbot@latest
# or: pnpm add -g clawdbot@latest

# Run onboarding wizard (installs daemon)
clawdbot onboard --install-daemon
```

The wizard walks through:
1. Gateway setup
2. Workspace configuration
3. Channel connections (WhatsApp, Telegram, etc.)
4. Skills installation

### From Source (Development)

```bash
git clone https://github.com/clawdbot/clawdbot.git
cd clawdbot

pnpm install
pnpm ui:build
pnpm build

pnpm clawdbot onboard --install-daemon

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
               +-- CLI (clawdbot ...)
               +-- WebChat UI
               +-- macOS app
               +-- iOS / Android nodes
```

## Configuration

Minimal config at `~/.clawdbot/clawdbot.json`:

```json5
{
  agent: {
    model: "anthropic/claude-opus-4-5"
  }
}
```

Full configuration reference: https://docs.clawd.bot/gateway/configuration

### Channel Setup

#### WhatsApp

```bash
clawdbot channels login  # Scan QR code
```

Configure allowlist in `~/.clawdbot/clawdbot.json`:

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
clawdbot gateway --port 18789 --verbose

# Send a message
clawdbot message send --to +1234567890 --message "Hello from Clawdbot"

# Talk to the assistant
clawdbot agent --message "Ship checklist" --thinking high

# Health check
clawdbot doctor

# Manage channels
clawdbot channels login
clawdbot channels list

# Manage pairings (DM security)
clawdbot pairing approve <channel> <code>
clawdbot pairing list
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
clawdbot pairing approve telegram ABC123
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

Run `clawdbot doctor` to check for risky configurations.

## Skills (Agent Workspace)

Clawdbot uses a skills system similar to aidevops agents:

- Workspace root: `~/clawd` (configurable)
- Injected prompts: `AGENTS.md`, `SOUL.md`, `TOOLS.md`
- Skills location: `~/clawd/skills/<skill>/SKILL.md`

## Integration with aidevops

Clawdbot complements aidevops by providing:

1. **Mobile access**: Interact with AI from WhatsApp/Telegram on your phone
2. **Always-on assistant**: Gateway runs as a daemon, always available
3. **Voice interface**: Talk Mode for hands-free interaction
4. **Multi-channel routing**: Different channels can route to different agents

### Recommended Setup

1. Install Clawdbot: `npm install -g clawdbot@latest`
2. Run onboarding: `clawdbot onboard --install-daemon`
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
clawdbot doctor

# View logs
clawdbot gateway --verbose

# Reset credentials
rm -rf ~/.clawdbot/credentials
clawdbot channels login
```

## Resources

- **Docs**: https://docs.clawd.bot
- **Getting Started**: https://docs.clawd.bot/start/getting-started
- **Configuration**: https://docs.clawd.bot/gateway/configuration
- **Security**: https://docs.clawd.bot/gateway/security
- **Discord**: https://discord.gg/clawd
- **GitHub**: https://github.com/clawdbot/clawdbot
