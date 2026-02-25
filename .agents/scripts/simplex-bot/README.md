# aidevops SimpleX Bot

Channel-agnostic gateway with SimpleX Chat as the first adapter.

## Prerequisites

- [Bun](https://bun.sh/) >= 1.0.0
- SimpleX Chat CLI running as WebSocket server (`simplex-chat -p 5225`)

## Setup

```bash
cd .agents/scripts/simplex-bot
bun install
```

## Usage

```bash
# Start the bot (SimpleX CLI must be running on port 5225)
bun run start

# Development mode (auto-reload)
bun run dev

# With custom port
SIMPLEX_PORT=5226 bun run start
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIMPLEX_PORT` | `5225` | WebSocket port for SimpleX CLI |
| `SIMPLEX_HOST` | `127.0.0.1` | WebSocket host |
| `SIMPLEX_BOT_NAME` | `AIBot` | Bot display name |
| `SIMPLEX_AUTO_ACCEPT` | `false` | Auto-accept contact requests |
| `SIMPLEX_LOG_LEVEL` | `info` | Log level (debug/info/warn/error) |

## Built-in Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/status` | Show aidevops system status |
| `/ask <question>` | Ask AI a question |
| `/tasks` | List open tasks |
| `/task <description>` | Create a new task |
| `/run <command>` | Execute aidevops CLI command (requires approval) |
| `/ping` | Check bot responsiveness |
| `/version` | Show bot version |

## Architecture

```text
SimpleX CLI (WebSocket :5225)
    |
SimplexAdapter (src/index.ts)
    |
CommandRouter -> CommandHandlers (src/commands.ts)
    |
aidevops CLI / AI model routing
```

The bot is designed as a channel-agnostic gateway. SimpleX is the first adapter.
Future adapters (Matrix, etc.) can plug into the same command router.

## Adding Custom Commands

```typescript
import type { CommandDefinition } from "./types";

const myCommand: CommandDefinition = {
  name: "mycommand",
  description: "My custom command",
  groupEnabled: true,
  dmEnabled: true,
  handler: async (ctx) => {
    return `Hello, ${ctx.args.join(" ") || "world"}!`;
  },
};

// Register with the bot adapter
bot.registerCommand(myCommand);
```

## Related

- `.agents/services/communications/simplex.md` — SimpleX subagent documentation
- `.agents/scripts/simplex-helper.sh` — CLI helper script
- `.agents/tools/security/opsec.md` — Operational security guidance
