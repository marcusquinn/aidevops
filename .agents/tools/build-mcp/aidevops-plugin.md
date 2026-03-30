---
description: Architecture design for aidevops-opencode plugin
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# aidevops-opencode Plugin Architecture

<!-- AI-CONTEXT-START -->

- **Status**: Implemented (t008.1 PR #1138, t008.2 PR #1149, t008.3 PR #1150)
- **Purpose**: Native OpenCode plugin wrapper for aidevops
- **Approach**: Single-file ESM plugin using hooks-based SDK pattern
- **Location**: `.agents/plugins/opencode-aidevops/index.mjs` + `package.json`
- **SDK**: `@opencode-ai/plugin` v1.1.56+ — full API: `index.d.ts` on npm
- **Key Decision**: Plugin complements `generate-opencode-agents.sh` — shell script handles primary agent config, plugin adds runtime hooks and tools. Shell script always takes precedence.

<!-- AI-CONTEXT-END -->

## Integration Layers

Static config (agents, subagent stubs, MCP configs, slash commands) is managed by `generate-opencode-agents.sh` and `setup.sh`. This plugin owns the runtime layer:

| Layer | Hook/Mechanism |
|-------|---------------|
| Agent loading + MCP registration | `config` hook |
| Custom tools | `tool` registration |
| Quality checks (pre/post) | `tool.execute.before` / `tool.execute.after` |
| Shell environment | `shell.env` hook |
| Compaction context | `experimental.session.compacting` hook |

## Hooks Implemented

### 1. Config Hook — Agent Loading + MCP Registration

**Agent Loading** (t008.1): Reads `~/.aidevops/agents/`, parses YAML frontmatter, injects subagent definitions into `config.agent`. Skips agents already configured (shell script takes precedence).

**MCP Registration** (t008.2): Data-driven registry of 12 MCP servers. Ensures MCPs are registered without re-running `generate-opencode-agents.sh`.

MCP registry fields: `name`, `type` (`"local"`/`"remote"`), `command`/`url`, `eager` (start at launch vs lazy), `toolPattern` (glob for permissions), `globallyEnabled`, `requiresBinary`, `macOnly`.

**Registered MCPs**:

| MCP | Type | Tools Global |
|-----|------|-------------|
| playwriter | local | yes |
| context7 | remote | no |
| augment-context-engine | local | no |
| outscraper | local | no |
| dataforseo | local | no |
| shadcn | local | no |
| claude-code-mcp | local | no |
| macos-automator | local | no (macOS) |
| ios-simulator | local | no (macOS) |
| sentry | remote | no |
| socket | remote | no |

All MCPs lazy-loaded (saves ~7K+ tokens on startup). Per-agent tool permissions applied via `AGENT_MCP_TOOLS` mapping (e.g. `@dataforseo` → `dataforseo_*`).

### 2. Custom Tools

| Tool | Description |
|------|-------------|
| `aidevops` | Run aidevops CLI commands (status, repos, features, etc.) |
| `aidevops_memory` | Recall or store cross-session memories (action: "recall"\|"store") |
| `aidevops_pre_edit_check` | Run pre-edit git safety check |
| `model-accounts-pool` | OAuth account pool management (provider credential rotation) |

### 3. Quality Hooks (t008.3)

**Pre-tool** (`tool.execute.before`):

- **Shell scripts (.sh)**: ShellCheck (`-x -S warning`), return statement validation, `local var="$1"` convention, secrets scanning
- **Markdown (.md)**: MD031 (blank lines around code blocks), trailing whitespace
- **All files**: Secrets scanning on Write (API keys, AWS keys, GitHub tokens)

**Post-tool** (`tool.execute.after`): Git operation detection, pattern tracking via cross-session memory, audit logging to `~/.aidevops/logs/quality-hooks.log`.

### 4. Shell Environment

Injects: `PATH` (prepends `~/.aidevops/agents/scripts/`), `AIDEVOPS_AGENTS_DIR`, `AIDEVOPS_WORKSPACE_DIR`, `AIDEVOPS_VERSION`.

### 5. Compaction Context

Preserves across context resets: active agent state, loop guardrails, session checkpoint, relevant memories (project-scoped, limit 5), git context, pending mailbox messages.

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Single-file ESM (no build step) | OpenCode loads `file://` ESM directly; avoids TypeScript compilation |
| Zero runtime dependencies | Built-in Node.js APIs + lightweight YAML parser; no `gray-matter` or `zod` |
| Complement shell script, don't replace | Shell script handles primary config; plugin adds runtime features |
| Subagents only in config hook | Primary agents need explicit config; auto-registration would override intentional settings |
| Data-driven MCP registry | Runtime binary detection and platform logic not expressible in static JSON |
| All MCPs lazy-loaded | Saves ~7K+ tokens on session startup |

## References

- [OpenCode Plugin SDK](https://opencode.ai/docs/plugins) — `@opencode-ai/plugin` npm package
- Implementation: `.agents/plugins/opencode-aidevops/index.mjs`
- Plan: `todo/PLANS.md` section "aidevops-opencode Plugin" (p001)
