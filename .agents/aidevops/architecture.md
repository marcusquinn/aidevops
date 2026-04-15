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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI DevOps Framework Context

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Services**: 25+ integrated (hosting, DNS, Git, code quality, email, etc.)
- **Pattern**: `./.agents/scripts/[service]-helper.sh [command] [account] [target] [options]`
- **Config**: `configs/[service]-config.json.txt` (template) → `configs/[service]-config.json` (gitignored)
- **Categories**: Infrastructure (4), Deployment (1), Git (4), DNS (5), Code Quality (4), Security (1), Email (1)
- **MCP Ports**: 3001 (LocalWP), 3002 (Vaultwarden), 3003+ (code audit, git platforms)
- **Extension**: See `.agents/aidevops/extension.md`

<!-- AI-CONTEXT-END -->

## Preferred Tool

**[Claude Code](https://Claude.ai/)** is the primary-tested AI coding agent. All features, agents, workflows, and MCP integrations are designed for Claude Code first.

Key integrations: agents via `generate-opencode-agents.sh`, 41 slash commands, compaction plugin at `.agents/plugins/opencode-aidevops/`, system prompt at `.agents/prompts/build.txt`, native tools at `.opencode/tool/*.ts`.

### OpenCode Native Tools (`.opencode/tool/`)

Files in `.opencode/tool/` are **OpenCode plugin tools** — TypeScript modules loaded by the Bun runtime, NOT shell-script wrappers. Before deleting any `.ts` file, check for unique logic (DB access, API calls, state management) — only thin wrappers are redundant.

| File | Purpose |
|------|---------|
| `ai-research.ts` | Spawns research queries via Anthropic API |
| `session-rename.ts` | Renames sessions via direct SQLite write — no HTTP API exists |

## Intelligence Over Scripts (Core Principle)

**Guide intelligence with agent docs. Do not replace it with deterministic bash logic.**

aidevops replaced a 37,000-line deterministic bash supervisor with a simple pattern: an AI agent reads guidance docs, fetches live state from GitHub, reasons, and acts. When the agent errs, fix the guidance — not a new script.

**When you encounter a supervisor/orchestration bug:** Improve the relevant agent doc. Never create a bash script to enforce what the agent should reason about. Never add state files, databases, or tracking layers.

**The test:** Fix adds a `.sh` file or state mechanism → wrong direction. Fix adds a paragraph of clear guidance → right track.

Helper scripts are for **deterministic utilities** (version bumping, file discovery, credential lookup) — not **judgment calls** (dispatch priority, stuck detection, triage).

## Agent Architecture

**Build+** is the unified coding agent for planning and implementation:

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

| Factor | MCP | curl subagent |
|--------|-----|---------------|
| Tool count | 25+ | 5-10 endpoints |
| Auth | OAuth2 token exchange | Simple Bearer/Basic/API key |
| Session frequency | Most sessions | Occasional |
| Statefulness | Persistent connection | Stateless REST |

**Two-tier MCP strategy** (all MCPs use `eager: false` — lazy-loaded on first tool call):

1. **Globally callable** (`globallyEnabled: true`): playwriter — tools visible to all agents
2. **Per-agent only** (`globallyEnabled: false`): all others — tools hidden globally, injected only for the agent that owns the MCP via `AGENT_MCP_TOOLS` in `agent-loader.mjs`

**How it works:** `eager: false` means the MCP process starts on the first tool call, not at OpenCode launch. No idle processes, no context bloat for sessions that don't use the MCP. The plugin (`mcp-registry.mjs` + `agent-loader.mjs`) is the authoritative source — it runs on every OpenCode startup and writes `opencode.json`. Do not edit `opencode.json` MCP entries directly; they are overwritten.

**Adding a new MCP requires two files** (both in `.agents/plugins/opencode-aidevops/`):
1. `mcp-registry.mjs` — add entry to `getMcpRegistry()` with `name`, `command`/`url`, `eager: false`, `toolPattern`, `globallyEnabled: false`
2. `agent-loader.mjs` — add `"agent-name": ["tool-pattern_*"]` to `AGENT_MCP_TOOLS`

**Replaced by curl subagent** (removed): hetzner, serper, ahrefs, hostinger — simple REST, no persistent state needed.

**Migrate MCP → curl subagent when:** simple REST with Bearer/Basic auth, <10 endpoints, no complex state, all patterns fit one markdown file. Saves ~2K context tokens permanently.

## Extension Guide

Full guide: `.agents/aidevops/extension.md`. Naming conventions: `tools/build-agent/build-agent.md`.

**Summary:** Helper scripts at `.agents/scripts/[service-name]-helper.sh`, config templates at `configs/[service-name]-config.json.txt`, docs at `.agents/[SERVICE-NAME].md`. Required functions: `check_dependencies`, `load_config`, `get_account_config`, `api_request`, `list_accounts`, `show_help`, `main`. Update `.gitignore`, `README.md`, `setup-wizard-helper.sh` after adding.

**Security standards** (all services): API token validation, rate limiting awareness, secure credential storage, input validation, error message sanitization, audit logging, confirmation prompts for destructive operations.

## Shell Helper Initialization

All shell scripts under `.agents/scripts/**/*.sh` MUST follow the canonical shared-variable initialization pattern. Short rule: source `shared-constants.sh` OR guard fallbacks with `[[ -z "${VAR+x}" ]]`. Never declare `RED`, `GREEN`, `YELLOW`, `BLUE`, `PURPLE`, `CYAN`, `WHITE`, or `NC` at top level without a guard, and never `readonly` those names outside `shared-constants.sh` itself.

Why the rule exists: PR #18728 fixed one instance of an unguarded re-assignment colliding with `readonly` in `shared-constants.sh`, which had killed `setup.sh` under `set -Eeuo pipefail` and broke auto-update for 4 days (GH#18702 primary, GH#18693 cascade victim). The same bug shape is latent in 18 other helpers today — this section exists to prevent the next occurrence.

Full guide with Patterns A/B/C, banned patterns, audit data, and migration checklist: **`reference/shell-style-guide.md`**. CI enforcement ships in t2053 Phase 2 via `shell-init-pattern-check.sh`.

## Knowledge Organization Model

The `.agents/` directory organizes knowledge along two axes: **strategy** (what to do) and **execution** (how to do it). Full conventions in `tools/build-agent/build-agent.md` "Folder Organization".

**Main agents** at root (e.g., `marketing-sales.md`, `seo.md`) own domain strategy. Their matching directories contain extended strategy knowledge loaded on demand.

| Directory | Contains | Used by |
|-----------|----------|---------|
| `tools/` | Capabilities — browser, git, database, code review, deployment | Any agent |
| `services/` | Integrations — hosting, payments, communications, email providers | Any agent |
| `workflows/` | Processes — git flow, release, PR review | Any agent |
| `reference/` | Operating rules — planning, sessions, security | Any agent |

**Scripts:** All scripts live flat in `scripts/` — shared utilities callable by any agent. Prefix naming (`email-*`, `seo-*`, `browser-*`) provides grouping. `*-helper.sh` = agent-callable; other `.sh` = framework infra.

**Flat files over nested folders:** Prefer prefix-based names over subdirectories. Max depth from `.agents/`: 2 levels. See `tools/build-agent/build-agent.md`.

**Ingested skills** retain the `-skill` suffix as a provenance marker for automated upstream update checks. On ingestion, upstream structure is transposed to `{name}-skill.md` + `{name}-skill/`. See `tools/build-agent/add-skill.md`.
