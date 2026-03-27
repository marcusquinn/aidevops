---
description: AI DevOps framework architecture context
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
---

# AI DevOps Framework Context

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Services**: 25+ integrated (hosting, DNS, Git, code quality, email, etc.)
- **Pattern**: `./.agents/scripts/[service]-helper.sh [command] [account] [target] [options]`
- **Config**: `configs/[service]-config.json.txt` (template) → `configs/[service]-config.json` (gitignored)

**Categories**:
- Infrastructure (4): Hostinger, Hetzner, Closte, Cloudron
- Deployment (1): Coolify
- Git (4): GitHub, GitLab, Gitea, Local
- DNS (5): Spaceship, 101domains, Cloudflare, Namecheap, Route53
- Code Quality (4): CodeRabbit, CodeFactor, Codacy, SonarCloud
- Security (1): Vaultwarden
- Email (1): Amazon SES

**MCP Ports**: 3001 (LocalWP), 3002 (Vaultwarden), 3003+ (code audit, git platforms)

**Extension**: Follow standard patterns in `.agents/aidevops/extension.md`

**Design Patterns**: aidevops implements industry-standard agent design patterns (see below)
<!-- AI-CONTEXT-END -->

## Preferred Tool

**[Claude Code](https://Claude.ai/)** is the recommended and primary-tested AI coding agent for aidevops. All features, agents, workflows, and MCP integrations are designed and tested for Claude Code first. Other AI assistants (OpenCode, Cursor, Zed, etc.) are supported as a courtesy but may not receive the same level of testing or integration depth.

Key integrations:
- **Agents**: Generated via `generate-opencode-agents.sh` with per-agent MCP tool filtering
- **Commands**: 41 slash commands deployed to `~/.config/opencode/commands/`
- **Plugins**: Compaction plugin at `.agents/plugins/opencode-aidevops/`
- **Prompts**: Custom system prompt at `.agents/prompts/build.txt`
- **OpenCode tools**: `.opencode/tool/*.ts` — native OpenCode plugin tools (loaded by the Bun runtime)

### OpenCode Native Tools (`.opencode/tool/`)

Files in `.opencode/tool/` are **OpenCode plugin tools** — TypeScript modules loaded by the Bun runtime that extend the agent's tool palette. They are NOT shell-script wrappers.

**Classification rule:** Before deleting or disabling any `.opencode/tool/*.ts` file, check whether it contains unique logic (DB access, API calls, state management) or is a thin wrapper that shells out to a helper script. Only wrappers are redundant; tools with native logic (like `bun:sqlite` access) have no shell equivalent.

| File | Type | Purpose |
|------|------|---------|
| `ai-research.ts` | Native logic | Spawns research queries via Anthropic API |
| `session-rename.ts` | Native logic | Renames sessions via direct SQLite write to `~/.local/share/opencode/opencode.db` — no HTTP API exists for this |

**Why this matters:** `session-rename.ts` was previously deleted by a cleanup task that treated all `.opencode/tool/` files as redundant wrappers. The tool contains unique logic — OpenCode CLI sessions don't expose an HTTP API; `Session.setTitle()` is a Drizzle ORM write to the local SQLite DB. There is no shell-script equivalent.

## Intelligence Over Scripts (Core Principle)

**Guide intelligence with agent docs. Do not replace it with deterministic bash logic.**

aidevops previously had a 37,000-line deterministic supervisor in bash (SQLite state DB, phase-based pipelines, grace periods, heartbeat windows, stale-state GC, dedup helpers). It was fragile, never reliable, and impossible to maintain. Every edge case spawned another script, another phase, another grace period — compounding complexity without improving outcomes.

The current architecture deliberately replaced all of that with a simple pattern: an AI agent reads `scripts/commands/pulse.md` (guidance), fetches live state from GitHub (the only state DB), reasons about what to do, and acts. When the agent makes mistakes, the fix is **better guidance in the agent doc** — not a new bash script, helper, or deterministic gate.

**When you encounter a supervisor/orchestration bug:**

1. Improve the guidance in the relevant agent doc (e.g., `scripts/commands/pulse.md`, `scripts/commands/full-loop.md`)
2. Add the missing knowledge the agent needed to make the right decision
3. Never create a bash script to enforce what the agent should reason about
4. Never add state files, databases, or tracking layers

**The test:** If your fix adds a `.sh` file or a new state mechanism to the orchestration layer, you are going in the wrong direction. If your fix adds a paragraph of clear guidance to an agent doc, you are on the right track.

Helper scripts are appropriate for **deterministic utilities** (version bumping, file discovery, credential lookup) — not for **decisions that require judgment** (what to dispatch, whether a task is stuck, how to prioritize).

## Agent Architecture

**Build+** is the unified coding agent for planning and implementation. It consolidates the former Plan+ and AI-DevOps agents:

- **Intent detection**: Automatically detects deliberation vs execution mode
- **Planning workflow**: Parallel explore agents, investigation phases, synthesis
- **Execution workflow**: Pre-edit git check, quality gates, autonomous iteration
- **Specialist subagents**: `@aidevops` for framework ops, `@plan-plus` for planning-only mode

## Agent Design Patterns

aidevops implements proven agent design patterns identified by Lance Martin (LangChain) and validated across successful agents like Claude Code, Manus, and Cursor. These patterns optimize for context efficiency and long-running autonomous operation.

### Pattern Alignment

| Pattern | Description | aidevops Implementation |
|---------|-------------|------------------------|
| **Give Agents a Computer** | Filesystem + shell access for persistent context | `~/.aidevops/.agent-workspace/`, helper scripts in `scripts/`, bash tools |
| **Multi-Layer Action Space** | Few tools, push actions to computer | Per-agent MCP filtering in `generate-opencode-agents.sh`, ~12-20 tools per agent |
| **Progressive Disclosure** | Load context on-demand, not upfront | Subagent tables in AGENTS.md, read-on-demand pattern, YAML frontmatter |
| **Offload Context** | Write intermediate results to filesystem | `.agent-workspace/work/[project]/` for persistent files, session trajectories |
| **Cache Context** | Prompt caching for cost efficiency | Stable instruction prefixes, avoid reordering between calls |
| **Isolate Context** | Sub-agents with separate context windows | Subagent markdown files with specific tool permissions |
| **Ralph Loop** | Iterative agent execution until task complete | `workflows/ralph-loop.md`, `full-loop-helper.sh` |
| **Evolve Context** | Learn from sessions, update memories | `/remember`, `/recall` with SQLite FTS5, `memory-helper.sh` |

### Key Implementation Details

**Multi-Layer Action Space** (`opencode.json` tools section):

```python
# Tools disabled globally, enabled per-agent
GLOBAL_TOOLS = {"gsc_*": False, "outscraper_*": False, ...}
AGENT_TOOLS = {
    "Build+": {"write": True, "context7_*": True, "bash": True, "playwriter_*": True, ...},
    "SEO": {"gsc_*": True, "google-analytics-mcp_*": True, ...},
}
```

**Progressive Disclosure** (AGENTS.md structure):

```markdown
## Subagent Folders
| Folder | Purpose | Key Subagents |
|--------|---------|---------------|
| `tools/browser/` | Browser automation | stagehand, playwright, crawl4ai |
```

Agents read full subagent content only when tasks require domain expertise.

**Ralph Loop** (iterative development):

```text
Task -> Implement -> Check -> Fix Issues -> Re-check -> ... -> Complete
         ^                      |
         +----------------------+ (loop until done)
```

**Memory System** (continual learning):

```bash
# Store learnings
/remember "Fixed CORS with nginx proxy_set_header"

# Recall across sessions
/recall "cors nginx"
```

### MCP Lifecycle Pattern

Decision framework for when to use an MCP server vs a curl-based subagent:

| Factor | Use MCP | Use curl subagent |
|--------|---------|-------------------|
| Tool count | 25+ tools (outscraper) | 5-10 endpoints |
| Auth complexity | OAuth2 token exchange (GSC) | Simple Bearer/Basic/API key |
| Session frequency | Used most sessions | Used occasionally |
| Context cost | Justified by frequency | Wasteful if rarely invoked |
| Statefulness | Needs persistent connection | Stateless REST calls |

**Three-tier MCP strategy**:

1. **Globally enabled** (always loaded, ~2K tokens each): augment-context-engine
2. **Enabled, tools disabled** (zero context until agent invokes): amazon-order-history, chrome-devtools, claude-code-mcp, context7, google-analytics-mcp, gsc, outscraper, playwriter, quickfile, repomix, etc.
3. **Replaced by curl subagent** (removed entirely): hetzner, serper, dataforseo, ahrefs, hostinger

**Pattern for tier 2** (in `opencode.json`):

```json
"mcp": { "service": { "enabled": true, ... } },
"tools": { "service_*": false },
"agent": { "AgentName": { "tools": { "service_*": true } } }
```

The MCP process runs but tools are hidden from all agents except those that explicitly enable them. Zero context overhead for agents that don't need the capability.

**When to migrate MCP → curl subagent**:
- API is simple REST with Bearer/Basic auth
- Fewer than ~10 endpoints needed
- No complex state management
- Subagent can document all patterns in a single markdown file
- Saves ~2K context tokens per session permanently

### References

- [Lance Martin's "Effective Agent Design" (Jan 2025)](https://x.com/RLanceMartin/status/2009683038272401719)
- [Anthropic's Claude Code architecture](https://www.anthropic.com/research/claude-code)
- [Manus agent design](https://manus.im/)
- [CodeAct paper on code execution](https://arxiv.org/abs/2402.01030)

## Extension Guide

### Adding New Providers/Services

**1. Create helper script** at `.agents/scripts/[service-name]-helper.sh`:

```bash
#!/bin/bash
# Standard header: color vars, print_info/success/warning/error functions
# Required functions: check_dependencies, load_config, get_account_config,
#   api_request, list_accounts, show_help, main
CONFIG_FILE="../configs/[service-name]-config.json"
```

**2. Create config template** at `configs/[service-name]-config.json.txt`:

```json
{
  "accounts": {
    "personal": {
      "api_token": "YOUR_[SERVICE]_API_TOKEN_HERE",
      "base_url": "https://api.[service].com"
    }
  },
  "default_settings": { "timeout": 30, "rate_limit": 60 }
}
```

**3. Create documentation** at `.agents/[SERVICE-NAME].md` covering: overview, configuration, usage examples, security practices, MCP integration, troubleshooting.

**4. Update framework files**: `.gitignore` (add config), `README.md` (add to provider list), `setup-wizard-helper.sh` (add to recommendations).

### Naming Conventions

- Helper scripts: `[service-name]-helper.sh` (lowercase, hyphenated)
- Config templates: `[service-name]-config.json.txt`; working: `[service-name]-config.json` (gitignored)
- Documentation: `[SERVICE-NAME].md` (uppercase, hyphenated)
- Functions: `action_description` (lowercase, underscored)
- Variables: `CONSTANT_NAME` (uppercase, underscored)

### Code Standards

All helper scripts must include: shebang, description comment, color definitions, `CONFIG_FILE`, `check_dependencies()`, `load_config()`, `show_help()`, `main()` with case statement, consistent error handling, proper exit codes.

### Security Standards

All services must implement: API token validation, rate limiting awareness, secure credential storage, input validation, error message sanitization, audit logging, confirmation prompts for destructive operations.
