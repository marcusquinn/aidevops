---
description: Real-time library documentation via Context7 MCP
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
mcp:
  - context7
---

# Context7 MCP Setup Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Real-time access to latest library/framework documentation
- **Package**: `@upstash/context7-mcp` (formerly `@context7/mcp-server`)
- **CLI**: `npx ctx7` for skills and setup commands
- **Strategy**: Hybrid backend - MCP first (`@context7`), CLI fallback (`@context7-cli`)
- **Telemetry**: Disable with `export CTX7_TELEMETRY_DISABLED=1`

**MCP Tools**:

- `resolve-library-id` -- Resolves library name to Context7 ID (e.g., "next.js" -> "/vercel/next.js")
- `query-docs` -- Retrieves documentation for a library ID with a query

**CLI equivalents**:

- `npx ctx7 library <name> [query] --json` -- Resolve library ID
- `npx ctx7 docs <libraryId> <query> --json` -- Query docs

**Common Library IDs**:

- Frontend: `/vercel/next.js`, `/facebook/react`, `/vuejs/vue`
- Backend: `/expressjs/express`, `/nestjs/nest`
- DB/ORM: `/prisma/prisma`, `/supabase/supabase`, `/drizzle-team/drizzle-orm`
- Tools: `/vitejs/vite`, `/typescript-eslint/typescript-eslint`
- AI/ML: `/openai/openai-node`, `/anthropic/anthropic-sdk-typescript`, `/langchain-ai/langchainjs`
- Media: `/websites/higgsfield_ai` (100+ image/video/audio models)

**Skills Registry**: [context7.com/skills](https://context7.com/skills) -- trust scores, install counts, prompt injection scanning.

```bash
npx ctx7 skills search react        # Search registry
npx ctx7 skills suggest             # Auto-suggest from project deps
npx ctx7 skills install /anthropics/skills pdf  # Install a skill
```

Skills from the Context7 registry can be imported into aidevops using `/add-skill`. See "Skill Discovery and Import" below.

<!-- AI-CONTEXT-END -->

## Installation & Setup

> **Note**: aidevops configures Context7 automatically via `setup.sh`. The sections below document config formats for other tools as MCP reference.

**Claude Code:**

```bash
claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp
```

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

**Remote server:**

```json
{
  "mcpServers": {
    "context7": {
      "url": "https://mcp.context7.com/mcp"
    }
  }
}
```

**Automated setup:**

```bash
npx ctx7 setup                # Auto-configures MCP server and rule
# Use --cursor, --claude, or --opencode to target a specific agent
```

## Usage

Core workflow: **resolve library ID → query docs**.

```bash
resolve-library-id("next.js")                            # -> "/vercel/next.js"
query-docs("/vercel/next.js", topic="routing")
query-docs("/vercel/next.js/v14.3.0-canary.87")          # Version-specific
query-docs("/facebook/react", tokens=10000)              # Adjust detail level
```

**Tips:**

- Always resolve before querying -- use specific names ("next.js" not "nextjs")
- Use `topic=` for focused results; adjust `tokens=` for detail level (default 5000)
- Try name variations if not found: without dots, shortened, with org prefix

## Troubleshooting

**Library not found:**

```bash
resolve-library-id("nextjs")      # Without dots
resolve-library-id("next")        # Shortened
resolve-library-id("vercel/next") # With org prefix
```

**Documentation seems outdated:** Query a specific version (`/vercel/next.js/v14.0.0`) or check if the library was renamed.

**MCP server not responding:**

```bash
npx -y @upstash/context7-mcp --help   # Test directly
# Then check AI assistant's MCP config and restart
```

## Skill Discovery and Import

Context7 maintains a searchable [skills registry](https://context7.com/skills). Skills follow the [Agent Skills](https://agentskills.io) open standard (`SKILL.md` format).

```bash
npx ctx7 skills search react
npx ctx7 skills search "typescript testing"
npx ctx7 skills suggest                              # Auto-suggest from project deps
npx ctx7 skills install /anthropics/skills pdf       # Specific skill
npx ctx7 skills install /anthropics/skills pdf --global  # All projects
npx ctx7 skills install /anthropics/skills pdf --claude  # Target client
```

### Importing into aidevops

Use `/add-skill` to convert Context7 skills to aidevops subagent format with frontmatter, update tracking, and placement in `.agents/`.

**Workflow:**

1. **Search**: `npx ctx7 skills search <query>`
2. **Evaluate**: trust score (7+ = high, 3-6.9 = medium, <3 = review carefully)
3. **Import**: `/add-skill <github-repo>` (e.g., `/add-skill anthropics/skills`)
4. **Verify**: imported skill passes security scanning (Cisco Skill Scanner)
5. **Deploy**: `./setup.sh` to create symlinks for all AI assistants

**`ctx7 skills install` vs `/add-skill`:**

| Aspect | `ctx7 skills install` | `/add-skill` |
|--------|----------------------|--------------|
| Format | SKILL.md (as-is) | Converted to aidevops subagent |
| Location | Client skill dirs (`.claude/skills/`) | `.agents/` directory |
| Tracking | None | `skill-sources.json` with update checks |
| Security | Context7 trust score | Cisco Skill Scanner + trust score |
| Cross-tool | Single client | All AI assistants via `setup.sh` |

### Managing Skills

```bash
npx ctx7 skills list                 # Installed Context7 skills
/add-skill list                      # aidevops-imported skills
/add-skill check-updates             # Check for upstream updates
npx ctx7 skills remove pdf           # Remove Context7 skill
/add-skill remove <name>             # Remove aidevops skill
```

**Related**: `scripts/commands/add-skill.md`, `tools/build-agent/add-skill.md`, `tools/deployment/agent-skills.md`

## Disabling Telemetry

```bash
CTX7_TELEMETRY_DISABLED=1 npx ctx7 skills search pdf   # Single command
export CTX7_TELEMETRY_DISABLED=1                        # Permanent (add to shell profile)
```

Recommended in automated/CI environments. Add the export to `~/.config/aidevops/credentials.sh` or your shell profile.
