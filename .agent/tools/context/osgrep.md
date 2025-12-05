# osgrep - Local Semantic Search

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Local semantic codebase search (open source alternative to Augment)
- **Type**: CLI tool (not MCP) - use via bash
- **Status**: ⚠️ Known indexing issues (v0.4.x) - see GitHub issues #58, #26
- **Install**: `npm install -g osgrep && osgrep setup`
- **Auth**: None required (100% local)
- **Data**: `~/.osgrep/` (indexes, models, config)
- **Docs**: <https://github.com/Ryandonofrio3/osgrep>

**Usage** (via bash):

```bash
# Semantic search in current directory
osgrep "where is authentication handled?"

# With options
osgrep "error handling" --per-file 5 -c

# Compact output (file paths only)
osgrep "API endpoints" --compact
```

**Claude Code Integration**:

```bash
osgrep install-claude-code
```

**Note**: osgrep is a CLI tool, not an MCP server. AI agents should use it
via bash commands. For Claude Code, use the native plugin system.

**Known Issues** (v0.4.15):
- Indexing may hang on some repositories (GitHub #58)
- Index may appear complete but be empty (GitHub #26)
- Server returns "unauthorized" for API requests
- Workaround: Use Claude Code plugin or wait for fixes

<!-- AI-CONTEXT-END -->

## What It Does

osgrep provides **local semantic search** for your codebase - like grep but
understanding concepts instead of just text patterns:

| Feature | grep/glob | osgrep |
|---------|-----------|--------|
| Text matching | Exact patterns | Semantic understanding |
| Privacy | Local | 100% local (no cloud) |
| Embeddings | None | Local via transformers.js |
| Natural language | No | Yes |
| Auto-indexing | No | Yes (per-repo) |
| Cross-file context | Manual | Automatic |

Use it to:

- Find related code using natural language queries
- Understand project architecture quickly
- Discover patterns and implementations
- Get context-aware search results
- Save ~20% LLM tokens with better context

## Comparison with Augment Context Engine

| Feature | osgrep | Augment |
|---------|--------|---------|
| Privacy | 100% local | Cloud-based |
| Auth | None required | Account + login |
| Node.js | 18+ | 22+ |
| First-time setup | ~150MB models | Account creation |
| Indexing | Auto per-repo | Cloud sync |
| Cost | Free (Apache 2.0) | Free tier available |

**Recommendation**: Use osgrep for local-first, privacy-focused development.
Use Augment for cloud sync and team features.

## Prerequisites

- **Node.js 18+** required
- **~150MB disk space** for embedding models (downloaded on first use)

Check Node.js version:

```bash
node --version  # Must be v18.x or higher
```

## Installation

### 1. Install osgrep CLI

```bash
npm install -g osgrep
```

### 2. Download Models (Recommended)

```bash
osgrep setup
```

This downloads embedding models (~150MB) upfront. If skipped, models download
automatically on first search.

### 3. Index Your Repository

```bash
cd your-project
osgrep index
```

Or just search - indexing happens automatically:

```bash
osgrep "how is authentication handled?"
```

## Commands Reference

### Search (default)

```bash
osgrep "how is the database connection pooled?"

# Options
osgrep "API rate limiting" -m 50          # Max 50 results (default: 25)
osgrep "error handling" --per-file 5      # Max 5 matches per file (default: 1)
osgrep "user validation" --compact        # File paths only (like grep -l)
osgrep "API handlers" -c                  # Show full chunk content
osgrep "search query" -s                  # Force re-index before search
osgrep "search query" -r                  # Reset and re-index from scratch
```

### Index

```bash
osgrep index                # Index current directory
osgrep index --dry-run      # See what would be indexed
```

### Serve (Background Server)

```bash
osgrep serve                # Start server (default port 4444)
OSGREP_PORT=5555 osgrep serve  # Custom port
```

The server provides:

- Hot search responses (<50ms)
- Live file watching with incremental re-indexing
- Health endpoint: `GET /health`
- Search endpoint: `POST /search`

### Other Commands

```bash
osgrep list     # List all indexed repositories
osgrep doctor   # Check installation health
```

## AI Tool Configurations

### OpenCode

Edit `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "osgrep": {
      "type": "local",
      "command": ["osgrep", "serve"],
      "enabled": true
    }
  },
  "tools": {
    "osgrep_*": false
  }
}
```

Then enable per-agent in the `agent` section:

```json
"agent": {
  "Build+": {
    "tools": {
      "osgrep_*": true
    }
  }
}
```

### Claude Code

osgrep has built-in Claude Code integration:

```bash
# Automatic setup
osgrep install-claude-code
```

Or manual setup:

```bash
# User scope (all projects)
claude mcp add-json osgrep-mcp --scope user '{"type":"stdio","command":"osgrep","args":["serve"]}'

# Project scope (current project only)
claude mcp add-json osgrep-mcp --scope project '{"type":"stdio","command":"osgrep","args":["serve"]}'
```

### Cursor

Go to Settings → Tools & MCP → New MCP Server.

**macOS/Linux**:

```json
{
  "mcpServers": {
    "osgrep": {
      "command": "osgrep",
      "args": ["serve"]
    }
  }
}
```

### Zed

Click ··· → Add Custom Server.

```json
{
  "osgrep": {
    "command": "osgrep",
    "args": ["serve"],
    "env": {}
  }
}
```

### GitHub Copilot

Create `.vscode/mcp.json` in your project root:

```json
{
  "servers": {
    "osgrep": {
      "type": "stdio",
      "command": "osgrep",
      "args": ["serve"]
    }
  },
  "inputs": []
}
```

### Kilo Code

Click MCP server icon → Edit Global MCP:

```json
{
  "mcpServers": {
    "osgrep": {
      "command": "osgrep",
      "type": "stdio",
      "args": ["serve"],
      "disabled": false,
      "alwaysAllow": ["search"]
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
    "osgrep": {
      "command": "osgrep",
      "args": ["serve"],
      "disabled": false,
      "autoApprove": ["search"]
    }
  }
}
```

### AntiGravity

Click MCP server icon → Manage MCP server → View raw config:

```json
{
  "mcpServers": {
    "osgrep": {
      "command": "osgrep",
      "args": ["serve"]
    }
  }
}
```

### Gemini CLI

Edit `~/.gemini/settings.json` (user level) or `.gemini/settings.json` (project):

```json
{
  "mcpServers": {
    "osgrep": {
      "command": "osgrep",
      "args": ["serve"]
    }
  }
}
```

## Configuration

### Ignoring Files

osgrep respects both `.gitignore` and `.osgrepignore` files. Create
`.osgrepignore` in your repository root for additional exclusions:

```gitignore
# Skip test fixtures
tests/fixtures/

# Skip generated files
dist/
build/

# Skip large data files
*.csv
*.json
```

### Repository Isolation

osgrep automatically creates unique indexes per repository:

- **Git repos with remote**: Uses remote URL (e.g., `github.com/user/repo`)
- **Git repos without remote**: Directory name + hash
- **Non-git directories**: Directory name + hash

No manual configuration needed - switching repos "just works".

### Data Locations

| Item | Location |
|------|----------|
| Indexes | `~/.osgrep/data/` |
| Models | `~/.osgrep/models/` |
| Server lock | `.osgrep/server.json` (per-repo) |

## Verification

After configuring any tool, test with this prompt:

```text
Search for authentication handling in this codebase using semantic search.
```

The AI should:

1. Confirm access to osgrep search
2. Execute a semantic search
3. Return relevant code locations

## Troubleshooting

### "osgrep: command not found"

```bash
# Check installation
npm list -g osgrep

# Reinstall
npm install -g osgrep
```

### "Node.js version too old"

```bash
# Check version
node --version

# Install Node 18+ via nvm
nvm install 18
nvm use 18

# Or via Homebrew (macOS)
brew install node@18
```

### "Index feels stale"

```bash
# Re-index the repository
osgrep index

# Or search with sync flag
osgrep "query" -s
```

### "Need fresh start"

```bash
# Remove all data and re-index
rm -rf ~/.osgrep/data
osgrep index
```

### "Models not downloading"

```bash
# Manually download models
osgrep setup

# Check doctor output
osgrep doctor
```

## Performance Notes

osgrep is designed to be efficient:

- **Bounded Concurrency**: Chunking/embedding use capped thread pools
- **Smart Chunking**: Uses tree-sitter for function/class boundaries
- **Deduplication**: Identical code blocks embedded once
- **Semantic Split Search**: Queries code and docs separately
- **Structural Boosting**: Function/class chunks score higher

## Updates

```bash
npm update -g osgrep
```

Check for updates at: <https://github.com/Ryandonofrio3/osgrep>

## Related Documentation

- [Augment Context Engine](augment-context-engine.md) - Cloud semantic retrieval
- [Context Builder](context-builder.md) - Token-efficient codebase packing
- [Context7](context7.md) - Library documentation lookup
