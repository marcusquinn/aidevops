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
- **Scope**: aidevops configures MCPs for OpenCode only. Other formats documented for MCP developers.

**Config Format Groups**:

| Format | Assistants |
|--------|------------|
| JSON (mcpServers) | OpenCode, Claude Desktop, Cursor, Windsurf, Kilo Code, Kiro, Gemini CLI |
| CLI command | Claude Code, Droid |
| VS Code MCP | GitHub Copilot, Continue.dev, Cody |
| Custom | Zed, Aider |
| Limited/None | Warp AI (terminal), Qwen (experimental), LiteLLM (proxy) |

<!-- AI-CONTEXT-END -->

All examples below use this placeholder command: `bun run /path/to/my-mcp/src/index.ts`

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

**With env vars** — wrap in bash: `["/bin/bash", "-c", "API_KEY=$MY_API_KEY bun run /path/to/my-mcp/src/index.ts"]`

**HTTP transport** — use `type: remote`:

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

## Claude Code (CLI)

```bash
claude mcp add my-mcp bun run /path/to/my-mcp/src/index.ts
claude mcp add my-mcp --env API_KEY=your-key bun run /path/to/my-mcp/src/index.ts

# Scope variants
claude mcp add-json my-mcp --scope user '{"type":"stdio","command":"bun","args":["run","/path/to/my-mcp/src/index.ts"]}'
claude mcp add-json my-mcp --scope project '{"type":"stdio","command":"bun","args":["run","/path/to/my-mcp/src/index.ts"]}'
```

## Standard mcpServers Format

Shared JSON schema. Config file paths differ per tool:

| Tool | Config location |
|------|-----------------|
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Cursor | Settings > Tools & MCP > New MCP Server |
| Windsurf | `.windsurf/mcp.json` (project) or global config |
| Gemini CLI | `~/.gemini/settings.json` (user) or `.gemini/settings.json` (project) |
| Kilo Code | MCP server icon > Edit Global MCP |
| Kiro | Cmd+Shift+P > **Kiro: Open workspace MCP config** or **Kiro: Open user MCP config** |

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "bun",
      "args": ["run", "/path/to/my-mcp/src/index.ts"],
      "env": { "API_KEY": "your-key" }
    }
  }
}
```

**Tool-specific extras:**

- **Cursor** — workspace-relative path: `"command": "bash", "args": ["-c", "cd \"${WORKSPACE_FOLDER_PATHS%%,*}\" && bun run src/index.ts"]`
- **Kilo Code** — add `"type": "stdio"`, `"disabled": false`, `"alwaysAllow": ["tool_name"]`
- **Kiro** — add `"disabled": false`, `"autoApprove": ["tool_name"]`

**HTTP transport** (Claude Desktop) — bridge via `mcp-remote-client`:

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

## VS Code MCP Format

### GitHub Copilot

Create `.vscode/mcp.json` in project root. Use in Agent mode:

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

## Other Formats

### Zed

Click ... > Add Custom Server:

```json
{
  "my-mcp": {
    "command": "bun",
    "args": ["run", "/path/to/my-mcp/src/index.ts"]
  }
}
```

### Aider

`.aider.conf.yml` or CLI flag:

```yaml
mcp-servers:
  - name: my-mcp
    command: bun
    args: [run, /path/to/my-mcp/src/index.ts]
```

CLI: `aider --mcp-server "bun run /path/to/my-mcp/src/index.ts"`

### Droid (Factory.AI)

```bash
droid mcp add my-mcp bun run /path/to/my-mcp/src/index.ts
droid mcp add my-mcp bun run /path/to/my-mcp/src/index.ts --env API_KEY=your-key
```

## Limited/No Native MCP

- **Warp AI**: No native MCP. Workaround: `alias mcp-my-tool="bun run /path/to/my-mcp/src/index.ts"`, or run OpenCode/Claude Code inside Warp.
- **Qwen CLI**: Experimental — verify current docs. Config: `mcp.servers.<name>` in `~/.qwen/config.json`.
- **LiteLLM**: Proxy/gateway, not an AI assistant. Configure the underlying MCP-capable client directly.

## Verification

After configuring, ask the AI: `What tools are available from my-mcp? Please list them.`
