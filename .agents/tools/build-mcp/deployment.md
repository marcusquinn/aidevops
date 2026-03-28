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

**Config Format Groups**:

| Format | Assistants |
|--------|------------|
| JSON (mcpServers) | OpenCode, Claude Desktop, Cursor, Windsurf, Kilo Code, Kiro, Gemini CLI |
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
  "tools": { "my-mcp_*": false },
  "agent": {
    "Build+": { "tools": { "my-mcp_*": true } }
  }
}
```

**With environment variables** — wrap in bash: `["/bin/bash", "-c", "API_KEY=$MY_API_KEY bun run /path/to/my-mcp/src/index.ts"]`

## Claude Code (CLI)

```bash
claude mcp add my-mcp bun run /path/to/my-mcp/src/index.ts
claude mcp add my-mcp --env API_KEY=your-key bun run /path/to/my-mcp/src/index.ts

# Scope variants
claude mcp add-json my-mcp --scope user '{"type":"stdio","command":"bun","args":["run","/path/to/my-mcp/src/index.ts"]}'
claude mcp add-json my-mcp --scope project '{"type":"stdio","command":"bun","args":["run","/path/to/my-mcp/src/index.ts"]}'
```

## Standard mcpServers Format

The following tools share the same `mcpServers` JSON schema. Config file paths differ:

| Tool | Config file |
|------|-------------|
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Cursor | Settings → Tools & MCP → New MCP Server |
| Windsurf | `.windsurf/mcp.json` (project) or global config |
| Gemini CLI | `~/.gemini/settings.json` (user) or `.gemini/settings.json` (project) |

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

**Cursor — workspace-relative path**:

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

### Kilo Code

Click MCP server icon → Edit Global MCP. Same `mcpServers` schema with tool approval fields:

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

### Kiro

Open command palette (Cmd+Shift+P) → **Kiro: Open workspace MCP config** (workspace) or **Kiro: Open user MCP config** (user):

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

## VS Code MCP Format

### GitHub Copilot

Create `.vscode/mcp.json` in project root. Use in Agent mode for MCP tool access:

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

### Continue.dev

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

### Cody (Sourcegraph)

Edit `.vscode/settings.json`:

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
    "args": ["run", "/path/to/my-mcp/src/index.ts"]
  }
}
```

## Aider

`.aider.conf.yml` or CLI flag:

```yaml
mcp-servers:
  - name: my-mcp
    command: bun
    args: [run, /path/to/my-mcp/src/index.ts]
```

CLI: `aider --mcp-server "bun run /path/to/my-mcp/src/index.ts"`

## Droid (Factory.AI)

```bash
droid mcp add my-mcp bun run /path/to/my-mcp/src/index.ts
droid mcp add my-mcp bun run /path/to/my-mcp/src/index.ts --env API_KEY=your-key
```

## Limited/No Native MCP

- **Warp AI**: No native MCP. Use `alias mcp-my-tool="bun run /path/to/my-mcp/src/index.ts"` as a workaround, or run OpenCode/Claude Code inside Warp.
- **Qwen CLI**: Experimental — verify current docs before using. Config key: `mcp.servers.<name>` in `~/.qwen/config.json`.
- **LiteLLM**: Proxy/gateway, not an AI assistant. Configure the underlying MCP-capable client directly.

## HTTP Transport (Remote Servers)

For MCPs deployed as HTTP services:

**OpenCode** — use `type: remote`:

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

**Claude Desktop** — bridge via `mcp-remote-client`:

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

After configuring, ask the AI: `What tools are available from my-mcp? Please list them.`
