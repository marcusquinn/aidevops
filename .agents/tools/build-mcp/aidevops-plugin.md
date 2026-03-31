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
- **Approach**: Single-file ESM plugin with SDK hooks
- **Location**: `.agents/plugins/opencode-aidevops/index.mjs` plus package metadata
- **SDK**: `@opencode-ai/plugin` v1.1.56+ (`index.d.ts` on npm)
- **Boundary**: `generate-opencode-agents.sh` and `setup.sh` own static config; the plugin owns runtime hooks and tools. Shell-generated config wins on conflicts.

<!-- AI-CONTEXT-END -->

## Runtime Surface

| Concern | Mechanism |
|---|---|
| Agent loading + MCP registration | `config` hook |
| Custom tools | `tool` registration |
| Quality checks | `tool.execute.before` / `tool.execute.after` |
| Shell environment | `shell.env` hook |
| Compaction context | `experimental.session.compacting` hook |

## Hooks

### Config hook

- **Agent loading (`t008.1`)**: reads `~/.aidevops/agents/`, parses YAML frontmatter, and injects subagent definitions into `config.agent`.
- **Precedence**: skips agents already configured by shell-generated config.
- **MCP registration (`t008.2`)**: uses a data-driven registry so MCP servers do not require re-running `generate-opencode-agents.sh`.
- **Registry fields**: `name`, `type` (`local` or `remote`), `command` or `url`, `eager`, `toolPattern`, `globallyEnabled`, `requiresBinary`, `macOnly`.
- **Lazy loading**: all MCPs are lazy-loaded, saving ~7K tokens at startup.
- **Per-agent permissions**: `AGENT_MCP_TOOLS` maps agents to tool globs, for example `@dataforseo` -> `dataforseo_*`.

Registered MCPs:

| MCP | Type | Global tools |
|---|---|---|
| `playwriter` | local | yes |
| `context7` | remote | no |
| `augment-context-engine` | local | no |
| `outscraper` | local | no |
| `dataforseo` | local | no |
| `shadcn` | local | no |
| `claude-code-mcp` | local | no |
| `macos-automator` | local | no (macOS only) |
| `ios-simulator` | local | no (macOS only) |
| `sentry` | remote | no |
| `socket` | remote | no |

### Custom tools

| Tool | Purpose |
|---|---|
| `aidevops` | Run aidevops CLI commands |
| `aidevops_memory` | Recall or store cross-session memory (`recall` or `store`) |
| `aidevops_pre_edit_check` | Run the pre-edit git safety check |
| `model-accounts-pool` | Manage OAuth account pools and provider rotation |

### Quality hooks (`t008.3`)

**Pre-tool (`tool.execute.before`)**

- Shell: ShellCheck (`-x -S warning`), return validation, `local var="$1"` enforcement, secret scanning
- Markdown: MD031 and trailing whitespace checks
- All writes: secret scanning for API keys, AWS keys, GitHub tokens, and similar patterns

**Post-tool (`tool.execute.after`)**

- Detect git operations
- Track patterns through cross-session memory
- Write audit logs to `~/.aidevops/logs/quality-hooks.log`

### Shell environment hook

Exports `PATH` (prepends `~/.aidevops/agents/scripts/`), `AIDEVOPS_AGENTS_DIR`, `AIDEVOPS_WORKSPACE_DIR`, and `AIDEVOPS_VERSION`.

### Compaction hook

Preserves active agent state, loop guardrails, session checkpoint, project-scoped memories (limit 5), git context, and pending mailbox messages.

## Design decisions

| Decision | Why |
|---|---|
| Single-file ESM, no build step | OpenCode loads `file://` ESM directly; avoids TypeScript compilation |
| Zero runtime dependencies | Uses built-in Node.js APIs plus a lightweight YAML parser, not `gray-matter` or `zod` |
| Plugin complements shell setup | Shell handles primary config; plugin adds runtime behavior |
| Subagents loaded only in `config` hook | Prevents auto-registration from overriding intentional primary-agent config |
| Data-driven MCP registry | Captures runtime binary checks and platform logic that static JSON cannot |
| All MCPs lazy-loaded | Reduces startup cost by ~7K tokens |

## References

- [OpenCode Plugin SDK](https://opencode.ai/docs/plugins)
- Implementation: `.agents/plugins/opencode-aidevops/index.mjs`
- Plan: `todo/PLANS.md` section `aidevops-opencode Plugin` (`p001`)
