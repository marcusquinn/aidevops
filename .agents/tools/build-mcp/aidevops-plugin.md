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

- **Status**: Implemented (`t008.1` PR #1138, `t008.2` PR #1149, `t008.3` PR #1150)
- **Purpose**: Native OpenCode plugin wrapper for aidevops
- **Approach**: Single-file ESM plugin using SDK hooks
- **Location**: `.agents/plugins/opencode-aidevops/index.mjs` plus package metadata
- **SDK**: `@opencode-ai/plugin` v1.1.56+ (`index.d.ts` on npm)
- **Boundary**: `generate-opencode-agents.sh` and `setup.sh` own static config; the plugin owns runtime hooks and tools. Shell-generated config wins on conflicts.

<!-- AI-CONTEXT-END -->

## Runtime surface

| Concern | Mechanism | Notes |
|---|---|---|
| Agent loading + MCP registration | `config` hook | Runtime-only layer |
| Custom tools | `tool` registration | Adds aidevops-specific tools |
| Quality checks | `tool.execute.before` / `tool.execute.after` | Enforces local quality gates |
| Shell environment | `shell.env` hook | Exports aidevops paths and version |
| Compaction context | `experimental.session.compacting` hook | Preserves loop state across resets |

## Hook details

### `config` hook

- **Agent loading (`t008.1`)**: reads `~/.aidevops/agents/`, parses YAML frontmatter, injects subagent definitions into `config.agent`, and skips agents already defined by shell-generated config.
- **MCP registration (`t008.2`)**: data-driven registry avoids re-running `generate-opencode-agents.sh`.
- **Registry fields**: `name`, `type` (`local`/`remote`), `command` or `url`, `eager`, `toolPattern`, `globallyEnabled`, `requiresBinary`, `macOnly`.
- **Startup policy**: all 11 MCPs are lazy-loaded, saving ~7K tokens at startup.
- **Per-agent permissions**: `AGENT_MCP_TOOLS` maps agents to tool globs, for example `@dataforseo` -> `dataforseo_*`.

| MCP | Type | Global tools |
|---|---|---|
| `playwriter` | local | yes |
| `augment-context-engine` | local | no |
| `context7` | remote | no |
| `outscraper` | local | no |
| `dataforseo` | local | no |
| `shadcn` | local | no |
| `claude-code-mcp` | local | no |
| `macos-automator` | local | no (macOS only) |
| `ios-simulator` | local | no (macOS only) |
| `sentry` | remote | no |
| `socket` | remote | no |

### `tool` registration

| Tool | Purpose |
|---|---|
| `aidevops` | Run aidevops CLI commands |
| `aidevops_memory` | Recall or store cross-session memory (`recall` or `store`) |
| `aidevops_pre_edit_check` | Run the pre-edit git safety check |
| `model-accounts-pool` | Manage OAuth account pools and provider rotation |

### `tool.execute.before` / `tool.execute.after` (`t008.3`)

| Phase | Coverage |
|---|---|
| Pre-tool | ShellCheck (`-x -S warning`), return validation, `local var="$1"` enforcement, Markdown MD031, trailing whitespace, secret scanning on writes |
| Post-tool | Git operation detection, pattern tracking via cross-session memory, audit logging to `~/.aidevops/logs/quality-hooks.log` |

### `shell.env` hook

Exports `PATH` (prepends `~/.aidevops/agents/scripts/`), `AIDEVOPS_AGENTS_DIR`, `AIDEVOPS_WORKSPACE_DIR`, and `AIDEVOPS_VERSION`.

### `experimental.session.compacting` hook

Preserves active agent state, loop guardrails, session checkpoint, project-scoped memories (limit 5), git context, and pending mailbox messages.

## Design decisions

| Decision | Why |
|---|---|
| Single-file ESM, no build step | OpenCode loads `file://` ESM directly; avoids TypeScript compilation |
| Zero runtime dependencies | Uses built-in Node.js APIs plus a lightweight YAML parser, not `gray-matter` or `zod` |
| Plugin complements shell setup | Shell handles primary config; plugin adds runtime behavior |
| Subagents load only in `config` hook | Prevents auto-registration from overriding intentional primary-agent config |
| Data-driven MCP registry | Captures runtime binary checks and platform logic that static JSON cannot |
| All MCPs lazy-loaded | Reduces startup cost by ~7K tokens |

## References

- [OpenCode Plugin SDK](https://opencode.ai/docs/plugins)
- Implementation: `.agents/plugins/opencode-aidevops/index.mjs`
- Plan: `todo/PLANS.md` section `aidevops-opencode Plugin` (`p001`)
