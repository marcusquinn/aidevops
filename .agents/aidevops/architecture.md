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

**Categories**: Infrastructure (4), Deployment (1), Git (4), DNS (5), Code Quality (4), Security (1), Email (1)

**MCP Ports**: 3001 (LocalWP), 3002 (Vaultwarden), 3003+ (code audit, git platforms)

**Extension**: See `.agents/aidevops/extension.md`
<!-- AI-CONTEXT-END -->

## Preferred Tool

**[Claude Code](https://Claude.ai/)** is the primary-tested AI coding agent. All features, agents, workflows, and MCP integrations are designed for Claude Code first. Other AI assistants are supported but may have less integration depth.

Key integrations: agents via `generate-opencode-agents.sh`, 41 slash commands, compaction plugin at `.agents/plugins/opencode-aidevops/`, system prompt at `.agents/prompts/build.txt`, native tools at `.opencode/tool/*.ts`.

### OpenCode Native Tools (`.opencode/tool/`)

Files in `.opencode/tool/` are **OpenCode plugin tools** — TypeScript modules loaded by the Bun runtime, NOT shell-script wrappers.

**Classification rule:** Before deleting any `.opencode/tool/*.ts` file, check whether it contains unique logic (DB access, API calls, state management) or is a thin wrapper. Only wrappers are redundant; tools with native logic (like `bun:sqlite` access) have no shell equivalent.

| File | Type | Purpose |
|------|------|---------|
| `ai-research.ts` | Native logic | Spawns research queries via Anthropic API |
| `session-rename.ts` | Native logic | Renames sessions via direct SQLite write — no HTTP API exists |

## Intelligence Over Scripts (Core Principle)

**Guide intelligence with agent docs. Do not replace it with deterministic bash logic.**

aidevops replaced a 37,000-line deterministic bash supervisor (SQLite state DB, phase pipelines, grace periods, heartbeat windows) with a simple pattern: an AI agent reads guidance docs, fetches live state from GitHub, reasons, and acts. When the agent errs, fix the guidance — not a new script.

**When you encounter a supervisor/orchestration bug:**

1. Improve guidance in the relevant agent doc (e.g., `scripts/commands/pulse.md`)
2. Add the missing knowledge the agent needed
3. Never create a bash script to enforce what the agent should reason about
4. Never add state files, databases, or tracking layers

**The test:** Fix adds a `.sh` file or state mechanism → wrong direction. Fix adds a paragraph of clear guidance → right track.

Helper scripts are for **deterministic utilities** (version bumping, file discovery, credential lookup) — not **judgment calls** (dispatch priority, stuck detection, triage).

## Agent Architecture

**Build+** is the unified coding agent for planning and implementation (consolidates former Plan+ and AI-DevOps agents):

- **Intent detection**: Auto-detects deliberation vs execution mode
- **Planning**: Parallel explore agents, investigation phases, synthesis
- **Execution**: Pre-edit git check, quality gates, autonomous iteration
- **Specialist subagents**: `@aidevops` for framework ops, `@plan-plus` for planning-only

## Agent Design Patterns

Implements proven patterns from Lance Martin (LangChain), validated across Claude Code, Manus, and Cursor.

| Pattern | aidevops Implementation |
|---------|------------------------|
| **Give Agents a Computer** | `~/.aidevops/.agent-workspace/`, helper scripts, bash tools |
| **Multi-Layer Action Space** | Per-agent MCP filtering via `generate-opencode-agents.sh`, ~12-20 tools/agent |
| **Progressive Disclosure** | Subagent tables in AGENTS.md, read-on-demand, YAML frontmatter |
| **Offload Context** | `.agent-workspace/work/[project]/` for persistent files |
| **Cache Context** | Stable instruction prefixes, avoid reordering between calls |
| **Isolate Context** | Subagent markdown files with specific tool permissions |
| **Ralph Loop** | `workflows/ralph-loop.md`, `full-loop-helper.sh` |
| **Evolve Context** | `/remember`, `/recall` with SQLite FTS5, `memory-helper.sh` |

### MCP Lifecycle Pattern

**When to use MCP vs curl subagent:**

| Factor | MCP | curl subagent |
|--------|-----|---------------|
| Tool count | 25+ | 5-10 endpoints |
| Auth | OAuth2 token exchange | Simple Bearer/Basic/API key |
| Session frequency | Most sessions | Occasional |
| Statefulness | Persistent connection | Stateless REST |

**Three-tier MCP strategy:**

1. **Globally enabled** (~2K tokens each): augment-context-engine
2. **Enabled, tools disabled** (zero context until invoked): amazon-order-history, chrome-devtools, claude-code-mcp, context7, google-analytics-mcp, gsc, outscraper, playwriter, quickfile, repomix, etc.
3. **Replaced by curl subagent** (removed): hetzner, serper, dataforseo, ahrefs, hostinger

Tier 2 pattern: MCP process runs but tools hidden from all agents except those that explicitly enable them via `opencode.json` agent tool overrides. Zero context overhead for non-using agents.

**Migrate MCP → curl subagent when:** simple REST with Bearer/Basic auth, <10 endpoints, no complex state, all patterns fit one markdown file. Saves ~2K context tokens permanently.

### References

- [Lance Martin's "Effective Agent Design" (Jan 2025)](https://x.com/RLanceMartin/status/2009683038272401719)
- [Anthropic's Claude Code architecture](https://www.anthropic.com/research/claude-code)
- [Manus agent design](https://manus.im/)
- [CodeAct paper on code execution](https://arxiv.org/abs/2402.01030)

## Extension Guide

Full extension guide: `.agents/aidevops/extension.md`

**Summary:** Helper scripts at `.agents/scripts/[service-name]-helper.sh`, config templates at `configs/[service-name]-config.json.txt`, docs at `.agents/[SERVICE-NAME].md`. Required functions: `check_dependencies`, `load_config`, `get_account_config`, `api_request`, `list_accounts`, `show_help`, `main`. Update `.gitignore`, `README.md`, `setup-wizard-helper.sh` after adding.

### Naming Conventions

- Scripts: `[service-name]-helper.sh` (lowercase, hyphenated)
- Config: `[service-name]-config.json.txt` (template); `[service-name]-config.json` (gitignored)
- Docs: `[SERVICE-NAME].md` (uppercase, hyphenated)
- Functions: `action_description` (lowercase, underscored)
- Variables: `CONSTANT_NAME` (uppercase, underscored)

### Security Standards

All services must implement: API token validation, rate limiting awareness, secure credential storage, input validation, error message sanitization, audit logging, confirmation prompts for destructive operations.

## Knowledge Organization Model

The `.agents/` directory organizes knowledge along two axes: **strategy** (what to do) and **execution** (how to do it). Full conventions in `tools/build-agent/build-agent.md` "Folder Organization".

### Strategy: Main Agent Directories

Main agents at root (e.g., `marketing.md`, `seo.md`) own domain strategy — methodology, audience knowledge, campaign planning. Their matching directories (`marketing/`, `seo/`) contain extended strategy knowledge loaded on demand.

### Execution: Cross-Domain Directories

| Directory | Contains | Used by |
|-----------|----------|---------|
| `tools/` | Capabilities — browser, git, database, code review, deployment | Any agent |
| `services/` | Integrations — hosting, payments, communications, email providers | Any agent |
| `workflows/` | Processes — git flow, release, PR review | Any agent |
| `reference/` | Operating rules — planning, sessions, security | Any agent |

### Scripts: Flat and Cross-Domain

All scripts live flat in `scripts/` — intentionally not grouped into domain folders. Scripts are shared utilities callable by any agent. The prefix naming convention (`email-*`, `seo-*`, `browser-*`) provides grouping via filesystem sort and glob patterns without imposing ownership.

- `*-helper.sh` suffix = agent-callable utilities (distinguishes from framework infrastructure scripts)
- Discovery: `ls scripts/email-*`, `rg --files -g "scripts/seo-*"`

### Flat Files Over Nested Folders

Inside any directory, prefer flat files with descriptive prefix-based names over nested subdirectories. File names provide sorting, grouping, and keyword discoverability. `ls {dir}/` should show everything at a glance. Max depth from `.agents/` should be 2 levels for agent knowledge. See `tools/build-agent/build-agent.md` for examples.

### Ingested Skills

External skills retain the `-skill` suffix as a provenance marker enabling automated upstream update checks. On ingestion, upstream structure (nested `references/`, `rules/`, `SKILL.md` entry points) is transposed to match our flat `{name}-skill.md` + `{name}-skill/` convention. See `tools/build-agent/add-skill.md`.
