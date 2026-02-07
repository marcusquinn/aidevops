---
description: MCP deployment and AI assistant configurations
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
---

# MCP Deployment - AI Assistant Configurations

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: MCP server configuration for AI assistants with native MCP support
- **Preferred**: OpenCode (native MCP, Tab-based agents)
- **Config Formats**: JSON (mcpServers), CLI commands, VS Code MCP

**Config Format Groups**:

| Format | Assistants |
|--------|------------|
| JSON (mcpServers) | OpenCode, Claude Desktop, Cursor, Windsurf, Kilo Code, Kiro, AntiGravity, Gemini CLI |
| CLI command | Claude Code, Droid |
| VS Code MCP | GitHub Copilot, Continue.dev, Cody |
| Custom | Zed, Aider |
| Limited/None | Warp AI (terminal), Qwen (experimental), LiteLLM (proxy) |

**Note**: aidevops configures MCPs for OpenCode only. The table above documents config formats for MCP developers targeting other tools.

<!-- AI-CONTEXT-END -->

## OpenCode (Preferred)

Edit `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "my-mcp": {
      "type": "local",
      "command": ["bun", "run", "/path/to/my-mcp/src/index.ts"],
      "enabled": true
    }
  },
  "tools": {
    "my-mcp_*": false
  },
  "agent": {
    "Build+": {
      "tools": {
        "my-mcp_*": true
      }
    }
  }
}
```

**With environment variables**:

```json
{
  "mcp": {
    "my-mcp": {
      "type": "local",
      "command": ["/bin/bash", "-c", "API_KEY=$MY_API_KEY bun run /path/to/my-mcp/src/index.ts"],
      "enabled": true
    }
  }
}
```

## Claude Code (CLI)

```bash
# Add MCP server
claude mcp add my-mcp bun run /path/to/my-mcp/src/index.ts

# With environment variables
claude mcp add my-mcp --env API_KEY=your-key bun run /path/to/my-mcp/src/index.ts

# User scope (all projects)
claude mcp add-json my-mcp --scope user '{"type":"stdio","command":"bun","args":["run","/path/to/my-mcp/src/index.ts"]}'

# Project scope
claude mcp add-json my-mcp --scope project '{"type":"stdio","command":"bun","args":["run","/path/to/my-mcp/src/index.ts"]}'
```

## Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "bun",
      "args": ["run", "/path/to/my-mcp/src/index.ts"],
      "env": {
        "API_KEY": "your-key"
      }
    }
  }
}
```

## Cursor

Settings → Tools & MCP → New MCP Server:

**macOS/Linux**:

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "bun",
      "args": ["run", "/path/to/my-mcp/src/index.ts"]
    }
  }
}
```

**With workspace path**:

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "bash",
      "args": ["-c", "cd \"${WORKSPACE_FOLDER_PATHS%%,*}\" && bun run src/index.ts"]
    }
  }
}
```

## Windsurf

Edit `.windsurf/mcp.json` in project or global config:

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "bun",
      "args": ["run", "/path/to/my-mcp/src/index.ts"]
    }
  }
}
```

## Continue.dev

Edit `.continue/config.json`:

```json
{
  "experimental": {
    "modelContextProtocolServers": [
      {
        "transport": {
          "type": "stdio",
          "command": "bun",
          "args": ["run", "/path/to/my-mcp/src/index.ts"]
        }
      }
    ]
  }
}
```

## Cody (Sourcegraph)

Edit VS Code settings or `.vscode/settings.json`:

```json
{
  "cody.experimental.mcp.servers": {
    "my-mcp": {
      "command": "bun",
      "args": ["run", "/path/to/my-mcp/src/index.ts"]
    }
  }
}
```

## Zed

Click ··· → Add Custom Server:

```json
{
  "my-mcp": {
    "command": "bun",
    "args": ["run", "/path/to/my-mcp/src/index.ts"],
    "env": {}
  }
}
```

## GitHub Copilot

Create `.vscode/mcp.json` in project root:

```json
{
  "servers": {
    "my-mcp": {
      "type": "stdio",
      "command": "bun",
      "args": ["run", "/path/to/my-mcp/src/index.ts"]
    }
  },
  "inputs": []
}
```

**Note**: Use in Agent mode for MCP tool access.

## Kilo Code

Click MCP server icon → Edit Global MCP:

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "bun",
      "type": "stdio",
      "args": ["run", "/path/to/my-mcp/src/index.ts"],
      "disabled": false,
      "alwaysAllow": ["tool_name"]
    }
  }
}
```

## Kiro

Open command palette (Cmd+Shift+P):

- **Kiro: Open workspace MCP config (JSON)** - Workspace level
- **Kiro: Open user MCP config (JSON)** - User level

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "bun",
      "args": ["run", "/path/to/my-mcp/src/index.ts"],
      "disabled": false,
      "autoApprove": ["tool_name"]
    }
  }
}
```

## AntiGravity

Click MCP server icon → Manage MCP server → View raw config:

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "bun",
      "args": ["run", "/path/to/my-mcp/src/index.ts"]
    }
  }
}
```

## Gemini CLI

Edit `~/.gemini/settings.json` (user) or `.gemini/settings.json` (project):

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "bun",
      "args": ["run", "/path/to/my-mcp/src/index.ts"]
    }
  }
}
```

## Droid (Factory.AI)

```bash
# Add MCP server
droid mcp add my-mcp bun run /path/to/my-mcp/src/index.ts

# With environment variables
droid mcp add my-mcp bun run /path/to/my-mcp/src/index.ts --env API_KEY=your-key
```

## Warp AI

> **Note**: Warp is a terminal with AI features, not a native MCP client. This is a workaround pattern.

Warp doesn't have native MCP support. Use shell aliases to invoke MCP tools manually:

```bash
# ~/.zshrc or ~/.bashrc
alias mcp-my-tool="bun run /path/to/my-mcp/src/index.ts"
```

For true MCP integration, use OpenCode or Claude Code in Warp terminal.

## Aider

Add to `.aider.conf.yml`:

```yaml
mcp-servers:
  - name: my-mcp
    command: bun
    args:
      - run
      - /path/to/my-mcp/src/index.ts
```

Or use command line:

```bash
aider --mcp-server "bun run /path/to/my-mcp/src/index.ts"
```

## Qwen CLI

> **Note**: Qwen CLI MCP support is experimental. Verify current documentation.

Edit `~/.qwen/config.json` (if supported):

```json
{
  "mcp": {
    "servers": {
      "my-mcp": {
        "command": "bun",
        "args": ["run", "/path/to/my-mcp/src/index.ts"]
      }
    }
  }
}
```

## LiteLLM

> **Note**: LiteLLM is a proxy/gateway, not an AI assistant. MCP support depends on the underlying client.

If using LiteLLM with an MCP-capable client, configure the client directly. LiteLLM proxies requests but doesn't manage MCP connections.

For direct tool calling via LiteLLM API, see their function calling documentation.

## HTTP Transport (Remote Servers)

For MCPs deployed as HTTP services:

### OpenCode

```json
{
  "mcp": {
    "my-mcp": {
      "type": "remote",
      "url": "https://my-mcp.example.com/mcp",
      "enabled": true
    }
  }
}
```

### Claude Desktop

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "npx",
      "args": ["-y", "mcp-remote-client", "https://my-mcp.example.com/mcp"]
    }
  }
}
```

## Verification

After configuring, test with:

```text
What tools are available from my-mcp? Please list them.
```

The AI should list all registered tools from your MCP server.
