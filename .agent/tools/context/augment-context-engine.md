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
  list: true
  webfetch: false
---

# Augment Context Engine MCP Setup

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Semantic codebase retrieval via Augment's context engine
- **Install**: `npm install -g @augmentcode/auggie@prerelease`
- **Auth**: `auggie login` (credentials in `~/.augment/session.json`)
- **MCP Tool**: `codebase-retrieval`
- **Docs**: <https://docs.augmentcode.com/context-services/mcp/overview>

**OpenCode Config**:

```json
"augment-context-engine": {
  "type": "local",
  "command": ["auggie", "--mcp"],
  "enabled": true
}
```

**Verification Prompt**:

```text
What is this project? Please use codebase retrieval tool to get the answer.
```

**Supported AI Tools**: OpenCode, Claude Code, Cursor, Zed, GitHub Copilot,
Kilo Code, Kiro, AntiGravity, Gemini CLI, Droid (Factory.AI)

**Enabled for Agents**: All 12 primary agents (Plan+, Build+, Accounting,
AI-DevOps, Content, Health, Legal, Marketing, Research, Sales, SEO, WordPress)

<!-- AI-CONTEXT-END -->

## What It Does

The Augment Context Engine provides **semantic codebase retrieval** - understanding
your code at a deeper level than simple text search:

| Feature | grep/glob | Augment Context Engine |
|---------|-----------|------------------------|
| Text matching | Exact patterns | Semantic understanding |
| Cross-file context | Manual | Automatic |
| Code relationships | None | Understands dependencies |
| Natural language | No | Yes |

Use it to:

- Find related code across your entire codebase
- Understand project architecture quickly
- Discover patterns and implementations
- Get context-aware code suggestions

## Prerequisites

- **Node.js 22+** required
- **Augment account** (free tier available at <https://augmentcode.com>)

Check Node.js version:

```bash
node --version  # Must be v22.x or higher
```

## Installation

### 1. Install Auggie CLI

```bash
npm install -g @augmentcode/auggie@prerelease
```

### 2. Authenticate

```bash
auggie login
```

This opens a browser for authentication. Credentials are stored in
`~/.augment/session.json`.

### 3. Verify Installation

```bash
auggie token print
```

Should output your access token (confirms authentication is working).

## AI Tool Configurations

### OpenCode

Edit `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "augment-context-engine": {
      "type": "local",
      "command": ["auggie", "--mcp"],
      "enabled": true
    }
  },
  "tools": {
    "augment-context-engine_*": false
  }
}
```

Then enable per-agent in the `agent` section:

```json
"agent": {
  "Build+": {
    "tools": {
      "augment-context-engine_*": true
    }
  }
}
```

### Claude Code

Add via CLI command:

```bash
# User scope (all projects)
claude mcp add-json auggie-mcp --scope user '{"type":"stdio","command":"auggie","args":["--mcp"]}'

# Project scope (current project only)
claude mcp add-json auggie-mcp --scope project '{"type":"stdio","command":"auggie","args":["--mcp"]}'

# With specific workspace
claude mcp add-json auggie-mcp --scope user '{"type":"stdio","command":"auggie","args":["-w","/path/to/project","--mcp"]}'
```

### Cursor

Go to Settings → Tools & MCP → New MCP Server.

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

**Windows** (update path):

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

Create `.vscode/mcp.json` in your project root:

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

**Note**: Use in Agent mode for codebase retrieval.

### Kilo Code

Click MCP server icon → Edit Global MCP:

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

Open command palette (Cmd+Shift+P / Ctrl+Shift+P):

- **Kiro: Open workspace MCP config (JSON)** - For workspace level
- **Kiro: Open user MCP config (JSON)** - For user level

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

### AntiGravity

Click MCP server icon → Manage MCP server → View raw config:

```json
{
  "mcpServers": {
    "augment-context-engine": {
      "command": "auggie",
      "args": ["--mcp", "-m", "default", "-w", "/path/to/your/project"]
    }
  }
}
```

**Note**: Update `/path/to/your/project` with your actual project path.

### Gemini CLI

Edit `~/.gemini/settings.json` (user level) or `.gemini/settings.json` (project):

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

With specific workspace:

```json
{
  "mcpServers": {
    "augment-context-engine": {
      "command": "auggie",
      "args": ["-w", "/path/to/project", "--mcp"]
    }
  }
}
```

### Droid (Factory.AI)

Add via CLI:

```bash
droid mcp add augment-code "auggie" --mcp

# With specific workspace
droid mcp add augment-code "auggie" -w /path/to/project --mcp
```

## Verification

After configuring any tool, test with this prompt:

```text
What is this project? Please use codebase retrieval tool to get the answer.
```

The AI should:

1. Confirm access to `codebase-retrieval` tool
2. Provide a semantic understanding of your project
3. Describe the main components and architecture

## Non-Interactive Setup (CI/CD)

For automation environments where `auggie login` isn't possible:

### 1. Get Authentication Token

```bash
auggie token print
```

Output:

```text
TOKEN={"accessToken":"your-access-token","tenantURL":"your-tenant-url","scopes":["read","write"]}
```

### 2. Configure Environment Variables

Add to your CI/CD environment or `~/.config/aidevops/mcp-env.sh`:

```bash
export AUGMENT_API_TOKEN="your-access-token"
export AUGMENT_API_URL="your-tenant-url"
```

### 3. Update MCP Config with Env Vars

**OpenCode** (`~/.config/opencode/opencode.json`):

```json
{
  "mcp": {
    "augment-context-engine": {
      "type": "local",
      "command": ["auggie", "--mcp"],
      "enabled": true,
      "env": {
        "AUGMENT_API_TOKEN": "your-access-token",
        "AUGMENT_API_URL": "your-tenant-url"
      }
    }
  }
}
```

**Claude Code**:

```bash
claude mcp add-json auggie-mcp --scope user '{"type":"stdio","command":"auggie","args":["--mcp"],"env":{"AUGMENT_API_TOKEN":"your-access-token","AUGMENT_API_URL":"your-tenant-url"}}'
```

**Droid**:

```bash
droid mcp add augment-code "auggie" --mcp --env AUGMENT_API_TOKEN=your-access-token --env AUGMENT_API_URL=your-tenant-url
```

## Credential Storage

| Method | Location | Use Case |
|--------|----------|----------|
| Interactive | `~/.augment/session.json` | Local development |
| Environment | `AUGMENT_API_TOKEN` + `AUGMENT_API_URL` | CI/CD, automation |
| aidevops pattern | `~/.config/aidevops/mcp-env.sh` | Consistent with other services |

## Troubleshooting

### "auggie: command not found"

```bash
# Check installation
npm list -g @augmentcode/auggie

# Reinstall
npm install -g @augmentcode/auggie@prerelease
```

### "Node.js version too old"

```bash
# Check version
node --version

# Install Node 22+ via nvm
nvm install 22
nvm use 22

# Or via Homebrew (macOS)
brew install node@22
```

### "Authentication failed"

```bash
# Re-authenticate
auggie login

# Verify token
auggie token print
```

### "MCP server not responding"

1. Check if auggie is running: `ps aux | grep auggie`
2. Restart your AI tool
3. Verify config JSON syntax

### "codebase-retrieval tool not found"

1. Ensure MCP is enabled in your config
2. Check that the agent has `augment-context-engine_*: true`
3. Restart the AI tool after config changes

## Updates

Check for configuration updates at:
<https://docs.augmentcode.com/context-services/mcp/overview>

The Augment team regularly adds support for new AI tools and updates configurations.

## Related Documentation

- [Context Builder](context-builder.md) - Token-efficient codebase packing
- [Context7](context7.md) - Library documentation lookup
- [Auggie CLI Overview](https://docs.augmentcode.com/cli/overview)
