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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# MCP Deployment - AI Assistant Configurations

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: MCP server configuration for AI assistants with native MCP support
- **Preferred**: OpenCode (native MCP, Tab-based agents)
- **Scope**: aidevops configures MCPs for OpenCode only. Other formats documented for MCP developers.

| Format | Assistants |
|--------|------------|
| JSON (mcpServers) | OpenCode, Claude Desktop, Cursor, Windsurf, Kilo Code, Kiro, Gemini CLI |
| CLI command | Claude Code, Droid |
| VS Code MCP | GitHub Copilot, Continue.dev, Cody |
| Custom | Zed, Aider |
| Limited/None | Warp AI, Qwen (experimental), LiteLLM (proxy) |

<!-- AI-CONTEXT-END -->

All examples use: `bun run /path/to/my-mcp/src/index.ts`

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

**Env vars** — wrap in bash: `["/bin/bash", "-c", "API_KEY=$MY_API_KEY bun run /path/to/my-mcp/src/index.ts"]`

**HTTP transport** — use `"type": "remote"` with `"url": "https://my-mcp.example.com/mcp"` (same structure, replace `type`/`command` with `type`/`url`).

## CLI Commands

### Claude Code

```bash
claude mcp add my-mcp bun run /path/to/my-mcp/src/index.ts
claude mcp add my-mcp --env API_KEY=your-key bun run /path/to/my-mcp/src/index.ts
claude mcp add-json my-mcp --scope user '{"type":"stdio","command":"bun","args":["run","/path/to/my-mcp/src/index.ts"]}'
```

### Droid (Factory.AI)

```bash
droid mcp add my-mcp bun run /path/to/my-mcp/src/index.ts
droid mcp add my-mcp bun run /path/to/my-mcp/src/index.ts --env API_KEY=your-key
```

## Standard mcpServers Format

Shared JSON schema used by Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`), Cursor (Settings > Tools & MCP), Windsurf (`.windsurf/mcp.json`), Gemini CLI (`~/.gemini/settings.json`), Kilo Code (MCP server icon > Edit Global MCP), and Kiro (Cmd+Shift+P > Kiro: Open MCP config).

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

**HTTP transport** (Claude Desktop) — bridge via `mcp-remote-client`: `"command": "npx", "args": ["-y", "mcp-remote-client", "https://my-mcp.example.com/mcp"]`

## VS Code MCP Format

All VS Code-based tools use stdio transport with the same command/args pattern. Config locations differ:

| Tool | Config file | Key path |
|------|-------------|----------|
| GitHub Copilot | `.vscode/mcp.json` | `servers.<name>` (Agent mode only) |
| Continue.dev | `.continue/config.json` | `experimental.modelContextProtocolServers[]` |
| Cody | `.vscode/settings.json` | `cody.experimental.mcp.servers.<name>` |

All use `"type": "stdio", "command": "bun", "args": ["run", "/path/to/my-mcp/src/index.ts"]` nested under their key path. Continue.dev wraps in a `transport` object within the array.

## Other Formats

**Zed** — Click ... > Add Custom Server: `{ "my-mcp": { "command": "bun", "args": ["run", "/path/to/my-mcp/src/index.ts"] } }`

**Aider** — `.aider.conf.yml`: `mcp-servers: [{ name: my-mcp, command: bun, args: [run, /path/to/my-mcp/src/index.ts] }]` or CLI: `aider --mcp-server "bun run /path/to/my-mcp/src/index.ts"`

## Limited/No Native MCP

- **Warp AI**: No native MCP. Run OpenCode/Claude Code inside Warp, or alias: `alias mcp-my-tool="bun run /path/to/my-mcp/src/index.ts"`
- **Qwen CLI**: Experimental — verify current docs. Config: `mcp.servers.<name>` in `~/.qwen/config.json`.
- **LiteLLM**: Proxy/gateway, not an AI assistant. Configure the underlying MCP-capable client directly.

## Verification

After configuring, ask the AI: `What tools are available from my-mcp? Please list them.`
