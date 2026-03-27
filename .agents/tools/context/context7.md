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
- **CLI**: `npx ctx7` — setup, skills, and doc queries
- **Strategy**: MCP first (`@context7`), CLI fallback (`@context7-cli`)
- **Telemetry**: `export CTX7_TELEMETRY_DISABLED=1`

**MCP Tools**: `resolve-library-id` → `query-docs`

**CLI equivalents**:

```bash
npx ctx7 library <name> [query] --json   # Resolve library ID
npx ctx7 docs <libraryId> <query> --json # Query docs
```

**Common Library IDs**:

- Frontend: `/vercel/next.js`, `/facebook/react`, `/vuejs/vue`
- Backend: `/expressjs/express`, `/nestjs/nest`
- DB/ORM: `/prisma/prisma`, `/supabase/supabase`, `/drizzle-team/drizzle-orm`
- Tools: `/vitejs/vite`, `/typescript-eslint/typescript-eslint`
- AI/ML: `/openai/openai-node`, `/anthropic/anthropic-sdk-typescript`, `/langchain-ai/langchainjs`
- Media: `/websites/higgsfield_ai` (100+ image/video/audio models)

**Skills Registry**: [context7.com/skills](https://context7.com/skills) — trust scores, install counts. Import into aidevops via `/add-skill`. See "Skill Discovery and Import" below.

<!-- AI-CONTEXT-END -->

## Installation & Setup

> aidevops configures Context7 automatically via `setup.sh`. The sections below are for manual/other-tool setup.

```bash
npx -y @upstash/context7-mcp --help   # Test the server
```

**Claude Code**: `claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp`

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{ "mcpServers": { "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] } } }
```

**Remote**: `{ "mcpServers": { "context7": { "url": "https://mcp.context7.com/mcp" } } }`

**Automated**: `npx ctx7 setup` (add `--cursor`, `--claude`, or `--opencode` to target a specific agent)

**Framework config**: `cp configs/context7-mcp-config.json.txt configs/context7-mcp-config.json`

## Usage

Core workflow: **resolve library ID → query docs**.

```bash
resolve-library-id("next.js")                              # -> "/vercel/next.js"
query-docs("/vercel/next.js", topic="routing")
query-docs("/vercel/next.js/v14.3.0-canary.87")            # Version-specific
query-docs("/facebook/react", tokens=10000)                # Adjust detail level
```

- Always resolve before querying — use specific names ("next.js" not "nextjs")
- Use `topic=` for focused results; `tokens=` adjusts detail (default 5000)
- Not found? Try without dots, shortened, or with org prefix

## Troubleshooting

**Library not found**: try `resolve-library-id("nextjs")`, `resolve-library-id("next")`, `resolve-library-id("vercel/next")`

**Outdated docs**: query a specific version (`/vercel/next.js/v14.0.0`) or check for renames.

**MCP not responding**: `npx -y @upstash/context7-mcp --help`, then check MCP config and restart.

## Skill Discovery and Import

```bash
npx ctx7 skills search react
npx ctx7 skills suggest              # Auto-suggest from project deps
npx ctx7 skills install /anthropics/skills pdf [--global] [--claude]
```

**Trust scores**: 7+ = high, 3–6.9 = medium, <3 = review carefully.

**Import into aidevops** (`/add-skill` converts to subagent format, registers for update tracking):

1. Search: `npx ctx7 skills search <query>`
2. Import: `/add-skill <github-repo>` → `.agents/`
3. Deploy: `./setup.sh`

| Aspect | `ctx7 skills install` | `/add-skill` |
|--------|----------------------|--------------|
| Format | SKILL.md (as-is) | Converted to aidevops subagent |
| Location | `.claude/skills/` | `.agents/` |
| Tracking | None | `skill-sources.json` with update checks |
| Security | Context7 trust score | Cisco Skill Scanner + trust score |
| Cross-tool | Single client | All AI assistants via `setup.sh` |

```bash
npx ctx7 skills list                 # Installed Context7 skills
/add-skill list                      # aidevops-imported skills
/add-skill check-updates             # Check for upstream updates
npx ctx7 skills remove pdf           # Remove Context7 skill
/add-skill remove <name>             # Remove aidevops skill
```

**Related**: `scripts/commands/add-skill.md`, `tools/build-agent/add-skill.md`, `tools/deployment/agent-skills.md`

## Telemetry

```bash
CTX7_TELEMETRY_DISABLED=1 npx ctx7 skills search pdf   # Single command
export CTX7_TELEMETRY_DISABLED=1                        # Permanent (add to shell profile)
```

Recommended in automated/CI environments. Add to `~/.config/aidevops/credentials.sh` or shell profile.
