---
description: Augment Context Engine for codebase semantic search
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
  auggie-mcp_*: true
  augment-context-engine_*: true
mcp:
  - auggie-mcp
  - augment-context-engine
---

# Augment Context Engine MCP Setup

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Semantic codebase retrieval via Augment's context engine
- **Install**: `npm install -g @augmentcode/auggie@prerelease` (Node.js 22+)
- **Auth**: `auggie login` → credentials in `~/.augment/session.json`
- **MCP Tool**: `codebase-retrieval`
- **Docs**: <https://docs.augmentcode.com/context-services/mcp/overview>

Use rg/fd for exact matches. Use Augment for semantic understanding, cross-file context, and natural language queries.

**Verification**: Ask `What is this project? Please use codebase retrieval tool to get the answer.`

<!-- AI-CONTEXT-END -->

## Installation

```bash
npm install -g @augmentcode/auggie@prerelease
auggie login        # opens browser for auth
auggie token print  # verify authentication
```

## Runtime Configurations

### Claude Code

```bash
# User scope (all projects)
claude mcp add-json auggie-mcp --scope user '{"type":"stdio","command":"auggie","args":["--mcp"]}'

# Project scope
claude mcp add-json auggie-mcp --scope project '{"type":"stdio","command":"auggie","args":["--mcp"]}'

# With specific workspace
claude mcp add-json auggie-mcp --scope user '{"type":"stdio","command":"auggie","args":["-w","/path/to/project","--mcp"]}'
```

### OpenCode

`~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "augment-context-engine": {
      "type": "local",
      "command": ["auggie", "--mcp"],
      "enabled": true
    }
  },
  "tools": { "augment-context-engine_*": false },
  "agent": {
    "Build+": { "tools": { "augment-context-engine_*": true } }
  }
}
```

### Cursor

Settings → Tools & MCP → New MCP Server.

**macOS/Linux**:

```json
{
  "mcpServers": {
    "augment-context-engine": {
      "command": "bash",
      "args": ["-c", "auggie --mcp -m default -w \"${WORKSPACE_FOLDER_PATHS%%,*}\""]
    }
  }
}
```

**Windows**:

```json
{
  "mcpServers": {
    "augment-context-engine": {
      "command": "powershell",
      "args": ["-Command", "auggie --mcp -m default -w \"($env:WORKSPACE_FOLDER_PATHS -split ',')[0]\""]
    }
  }
}
```

### Zed

Click ··· → Add Custom Server.

**macOS/Linux**:

```json
{
  "Augment-Context-Engine": {
    "command": "bash",
    "args": ["-c", "auggie -m default --mcp -w $(pwd)"],
    "env": {}
  }
}
```

**Windows**:

```json
{
  "Augment-Context-Engine": {
    "command": "auggie",
    "args": ["--mcp", "-m", "default", "-w", "/path/to/your/project"],
    "env": {}
  }
}
```

### GitHub Copilot

`.vscode/mcp.json` in project root (Agent mode):

```json
{
  "servers": {
    "augmentcode": {
      "type": "stdio",
      "command": "auggie",
      "args": ["--mcp", "-m", "default"]
    }
  },
  "inputs": []
}
```

### Kilo Code

MCP server icon → Edit Global MCP:

```json
{
  "mcpServers": {
    "augment-context-engine": {
      "command": "auggie",
      "type": "stdio",
      "args": ["--mcp"],
      "disabled": false,
      "alwaysAllow": ["codebase-retrieval"]
    }
  }
}
```

### Kiro

Cmd+Shift+P → "Kiro: Open workspace MCP config (JSON)" or "Kiro: Open user MCP config (JSON)":

```json
{
  "mcpServers": {
    "Augment-Context-Engine": {
      "command": "auggie",
      "args": ["--mcp", "-m", "default", "-w", "./"],
      "disabled": false,
      "autoApprove": ["codebase-retrieval"]
    }
  }
}
```

### Gemini CLI

`~/.gemini/settings.json` (user) or `.gemini/settings.json` (project):

```json
{
  "mcpServers": {
    "augment-context-engine": {
      "command": "auggie",
      "args": ["--mcp"]
    }
  }
}
```

With specific workspace: add `"-w", "/path/to/project"` before `"--mcp"`.

### Droid (Factory.AI)

```bash
droid mcp add augment-code "auggie" --mcp
# With workspace: droid mcp add augment-code "auggie" -w /path/to/project --mcp
```

## Non-Interactive Setup (CI/CD)

```bash
auggie token print
# Output: TOKEN={"accessToken":"...","tenantURL":"...","scopes":["read","write"]}
```

Set env vars for headless use:

```bash
export AUGMENT_API_TOKEN="your-access-token"
export AUGMENT_API_URL="your-tenant-url"
```

Pass via MCP config `env` block (OpenCode, Claude Code) or `--env` flags (Droid).

| Method | Location |
|--------|----------|
| Interactive | `~/.augment/session.json` |
| Environment | `AUGMENT_API_TOKEN` + `AUGMENT_API_URL` |
| aidevops | `~/.config/aidevops/credentials.sh` |

## Troubleshooting

| Error | Fix |
|-------|-----|
| `auggie: command not found` | `npm install -g @augmentcode/auggie@prerelease` |
| Node.js version too old | `nvm install 22 && nvm use 22` or `brew install node@22` |
| Authentication failed | `auggie login` then `auggie token print` |
| MCP server not responding | Check `ps aux \| grep auggie`, restart AI tool, verify JSON syntax |
| `codebase-retrieval` not found | Enable MCP in config, set `augment-context-engine_*: true` for agent, restart |

## Related

- [Context Builder](context-builder.md) — Token-efficient codebase packing
- [Context7](context7.md) — Library documentation lookup
- [Auggie CLI Overview](https://docs.augmentcode.com/cli/overview)
