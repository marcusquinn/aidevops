---
description: On-demand MCP tool discovery - find and enable MCPs as needed
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

# MCP On-Demand Discovery

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Discover MCP tools without loading all definitions upfront
- **Pattern**: Search → Find MCP → Enable → Use
- **Script**: `~/.aidevops/agents/scripts/mcp-index-helper.sh`

**Commands**:

```bash
# Search for tools by capability
mcp-index-helper.sh search "screenshot"
mcp-index-helper.sh search "seo keyword"

# List all MCPs or specific one
mcp-index-helper.sh list
mcp-index-helper.sh list context7

# Find which MCP provides a tool
mcp-index-helper.sh get-mcp "query-docs"

# Show index status
mcp-index-helper.sh status
```

**Why this matters**:
- MCP tool definitions consume context tokens
- Loading all MCPs upfront wastes tokens on unused tools
- On-demand discovery loads only what's needed

<!-- AI-CONTEXT-END -->

## Architecture

### The Problem

Each MCP server exposes tool definitions that consume context tokens:
- `context7`: ~2K tokens for 2 tools
- `repomix`: ~5K tokens for 8 tools
- `chrome-devtools`: ~17K tokens for 50+ tools

Loading all MCPs globally means every conversation pays this token cost, even when most tools aren't used.

### The Solution

**Lazy-load MCP pattern** (inspired by [Amp's approach](https://ampcode.com/news/lazy-load-mcp-with-skills)):

1. **Index**: Extract tool descriptions into SQLite FTS5 database
2. **Search**: Agent queries index for needed capability
3. **Discover**: Index returns which MCP provides the tool
4. **Enable**: Agent enables that specific MCP
5. **Use**: Tool is now available with minimal token overhead

### Index Structure

```text
~/.aidevops/.agent-workspace/mcp-index/
└── mcp-tools.db          # SQLite FTS5 database
    ├── mcp_tools         # Tool metadata
    ├── mcp_tools_fts     # Full-text search index
    └── sync_metadata     # Sync state tracking
```

## Usage Patterns

### Pattern 1: Capability Search

When you need a capability but don't know which MCP provides it:

```bash
# "I need to take screenshots of web pages"
mcp-index-helper.sh search "screenshot web"

# Output:
# MCP         Tool                    Description
# playwriter  playwriter_screenshot   Take screenshot of current page
# chrome-devtools  chrome-devtools_screenshot  Capture page screenshot
```

### Pattern 2: Tool Lookup

When you know a tool name but need the MCP:

```bash
mcp-index-helper.sh get-mcp "query-docs"
# Output: context7
```

### Pattern 3: MCP Exploration

When exploring what tools an MCP provides:

```bash
mcp-index-helper.sh list dataforseo
# Output:
# Tool                    Description
# dataforseo_serp         Search engine results page data
# dataforseo_keywords     Keyword research and metrics
# dataforseo_backlinks    Backlink analysis
```

## Integration with Agents

### Subagent Frontmatter

Subagents declare which MCPs they need:

```yaml
---
description: SEO keyword research
mode: subagent
tools:
  dataforseo_*: true
  serper_*: true
---
```

### Main Agent Pattern

Main agents don't enable MCPs directly. They:
1. Reference subagents that have MCP access
2. Or use the discovery pattern to find needed tools

```markdown
# Good: Main agent references subagent
For keyword research, invoke `@dataforseo` subagent.

# Bad: Main agent enables MCP directly
tools:
  dataforseo_*: true  # DON'T DO THIS in main agents
```

### OpenCode Configuration

In `opencode.json`, MCPs are disabled globally and enabled per-agent:

```json
{
  "tools": {
    "dataforseo_*": false,
    "serper_*": false
  },
  "agent": {
    "SEO": {
      "tools": {
        "dataforseo_*": true,
        "serper_*": true
      }
    }
  }
}
```

## Sync and Maintenance

### Automatic Sync

The index auto-syncs when:
- `opencode.json` is modified
- Index is older than 24 hours
- Index doesn't exist

### Manual Sync

```bash
# Sync from current config
mcp-index-helper.sh sync

# Force rebuild (clears and recreates)
mcp-index-helper.sh rebuild
```

### Status Check

```bash
mcp-index-helper.sh status

# Output:
# Database: ~/.aidevops/.agent-workspace/mcp-index/mcp-tools.db
# Last sync: 2025-01-21 05:30:00
# MCP servers: 12
# Tools indexed: 45
# Globally enabled tools: 8
# Disabled (on-demand): 37
```

## Token Savings

Example savings from on-demand loading:

| Scenario | All MCPs Loaded | On-Demand | Savings |
|----------|-----------------|-----------|---------|
| Simple code task | ~50K tokens | ~5K tokens | 90% |
| SEO analysis | ~50K tokens | ~12K tokens | 76% |
| Browser automation | ~50K tokens | ~20K tokens | 60% |

The savings compound over a conversation as context accumulates.

## Future: OpenCode includeTools Support

When OpenCode implements `includeTools` filtering ([#7399](https://github.com/anomalyco/opencode/issues/7399)), agents can specify exactly which tools they need:

```yaml
---
mcp_requirements:
  chrome-devtools:
    tools: [navigate_page, take_screenshot]  # Only these 2 of 50+ tools
---
```

This would reduce chrome-devtools from ~17K to ~1.5K tokens.

The current index prepares for this by tracking tool-level metadata.

## Related

- `tools/build-agent/build-agent.md` - MCP placement rules
- `aidevops/architecture.md` - Agent design patterns
- `generate-opencode-agents.sh` - Agent generation with MCP config
