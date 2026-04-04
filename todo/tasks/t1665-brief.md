---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1665: Runtime Abstraction Layer — Decouple Framework from Specific AI CLI Runtimes

## Origin

- **Created:** 2026-03-26
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human + ai-interactive)
- **Conversation context:** User observed that adding Codex CLI support would require touching 45+ files, and that the framework should be agnostic to support Codex, Cursor, Droid (factory.ai), and future runtimes without per-runtime code duplication.

## What

A runtime abstraction layer consisting of three core components:

1. **Runtime Registry** (`runtime-registry.sh`) — single data source defining each runtime's identity, config paths, formats, process patterns, and capabilities
2. **MCP Config Adapter** (`mcp-config-adapter.sh`) — transforms universal MCP server definitions into per-runtime config format (JSON/TOML/CLI)
3. **Prompt Injection Adapter** (`prompt-injection-adapter.sh`) — deploys system prompts (build.txt, AGENTS.md) via each runtime's native mechanism

Plus: unified generator script, migration of 45 accidentally-coupled scripts, and concrete runtime entries for Codex/Cursor/Droid.

## Why

- Adding a new runtime currently requires modifying 45+ files and duplicating 900+ line generator scripts
- 4 generator scripts (4,102 lines total) share ~80% content — each new runtime would add another 900+ line copy
- 6+ scripts contain duplicate `if command -v opencode ... elif command -v claude ...` detection patterns
- The AI CLI landscape is expanding rapidly (Codex, Cursor, Droid, Gemini CLI, Aider, Kiro, Kilo Code, Windsurf, Continue.dev) — the current approach doesn't scale
- Codex CLI has a broken MCP_DOCKER config that our setup should fix during config generation

## How (Approach)

### Architecture: 4 independent dimensions

What varies independently across runtimes:

| Dimension | Examples | Abstraction |
|-----------|----------|-------------|
| Runtime identity | binary name, config paths, process patterns | Runtime Registry |
| MCP config format | JSON `.mcp`, JSON `.mcpServers`, TOML `[mcp_servers]`, CLI `claude mcp add` | MCP Config Adapter |
| System prompt mechanism | `instructions` field, AGENTS.md auto-discovery, `.cursorrules`, `skills/` dir | Prompt Injection Adapter |
| Agent/command content | markdown bodies, agent definitions, slash commands | Shared templates (already mostly shared) |

### Runtime Registry data model (Bash 3.2 compatible — parallel arrays)

```bash
# Each index position represents one runtime
RUNTIME_IDS=("opencode" "claude" "codex" "cursor" "droid" "gemini" "windsurf" "continue" "kilo" "kiro" "aider")
RUNTIME_BINARIES=("opencode" "claude" "codex" "cursor" "droid" "gemini" "windsurf" "continue" "kilo" "kiro" "aider")
RUNTIME_CONFIG_PATHS=("~/.config/opencode/opencode.json" "" "~/.codex/config.toml" "~/.cursor/mcp.json" "" "~/.gemini/settings.json" "~/.codeium/windsurf/mcp_config.json" "~/.continue/config.json" "~/.kilo/mcp.json" "~/.kiro/mcp.json" "")
RUNTIME_CONFIG_FORMATS=("json-opencode" "cli-claude" "toml-codex" "json-mcpServers" "cli-droid" "json-mcpServers" "json-mcpServers" "json-array-continue" "json-mcpServers" "json-mcpServers" "yaml-aider")
RUNTIME_MCP_ROOT_KEYS=("mcp" "" "mcp_servers" "mcpServers" "" "mcpServers" "mcpServers" "mcpServers" "mcpServers" "mcpServers" "")
RUNTIME_COMMAND_DIRS=("~/.config/opencode/command" "~/.claude/commands" "~/.codex/skills" "" "" "" "" "" "" "" "")
RUNTIME_PROMPT_MECHANISM=("json-instructions" "agents-md-autodiscovery" "codex-instructions" "cursorrules" "factory-skills" "gemini-agents-md" "windsurfrules" "continue-rules" "kilo-rules" "kiro-rules" "aider-conventions")
RUNTIME_SESSION_DBS=("~/.local/share/opencode/opencode.db" "" "" "" "" "" "" "" "" "" "")
RUNTIME_PROCESS_PATTERNS=("opencode|opencode-ai" "claude|claude-ai" "codex" "cursor" "droid" "gemini" "windsurf" "" "" "" "aider")
```

### MCP Config Adapter format transforms

Universal definition (input):
```json
{"name": "my-mcp", "command": "npx", "args": ["-y", "@example/mcp"], "env": {"KEY": "val"}, "transport": "stdio"}
```

Per-runtime output:
- **OpenCode**: merge command+args into `command` array, rename `env` to `environment`, wrap under `.mcp`, add `type: "local"`, `enabled: true`
- **Claude Code**: call `claude mcp add-json NAME --scope user '{...}'` with `type: "stdio"`
- **Codex**: emit TOML `[mcp_servers.NAME]` with `command` string and `args` array
- **Cursor/Windsurf/Gemini/Kilo/Kiro**: wrap under `.mcpServers` with `command` string, `args` array, `env` object
- **Droid**: call `droid mcp add NAME COMMAND ARGS --env KEY=VALUE`
- **Continue.dev**: append to `mcpServers` array with `transport: {type, command, args}`
- **Validation**: before writing any MCP entry, verify `command` binary exists (`command -v`); skip with warning if missing (fixes Codex Docker MCP issue)

### System prompt injection mechanisms per runtime

| Runtime | Mechanism | How aidevops uses it |
|---------|-----------|---------------------|
| OpenCode | `instructions` field in `opencode.json` (array of file paths, auto-loaded every session) | Points to `~/.aidevops/agents/AGENTS.md` |
| Claude Code | `~/.config/Claude/AGENTS.md` + `~/.claude/AGENTS.md` (auto-discovered by Claude Code) + `prompts/build.txt` (via `--system-prompt` or project config) | AGENTS.md files with pointer to framework; build.txt loaded via project CLAUDE.md |
| Codex | `~/.codex/instructions.md` (global) + `.codex/instructions.md` (per-project) + `~/.codex/skills/` (skill files) | Deploy instructions.md pointing to AGENTS.md; symlink skills/ to .agents/ |
| Cursor | `.cursorrules` (per-project) + `~/.cursor/rules/` (global rules dir) + AGENTS.md auto-discovery | Symlink `.cursor/rules` to `.agents/`; deploy AGENTS.md |
| Droid | `~/.factory/skills/` (skill files) + AGENTS.md auto-discovery | Symlink `.factory/skills` to `.agents/` |
| Gemini CLI | `~/.gemini/AGENTS.md` (global) + `.gemini/AGENTS.md` (per-project) | Deploy AGENTS.md with framework pointer |
| Windsurf | `.windsurfrules` (per-project) + global config | Deploy rules file with framework pointer |
| Continue.dev | `.continuerules` (per-project) + `~/.continue/config.json` system message | Deploy rules file |
| Kilo/Kiro | `.kilo/rules/` or `.kiro/rules/` + AGENTS.md | Deploy AGENTS.md |
| Aider | `.aider.conf.yml` `read:` field + `--read` CLI flag + conventions files | Add AGENTS.md to `read:` list |

### Key files to modify/create

**New files:**
- `.agents/scripts/runtime-registry.sh` — registry data + lookup functions
- `.agents/scripts/mcp-config-adapter.sh` — universal → per-runtime MCP transform
- `.agents/scripts/prompt-injection-adapter.sh` — per-runtime system prompt deployment
- `.agents/scripts/generate-runtime-config.sh` — unified generator replacing 4 scripts

**Files to migrate (top 20 by impact):**
- `setup.sh:387-858` — replace `find_opencode_config()`, per-runtime setup steps with registry loop
- `setup-modules/config.sh:102-165` — merge `update_opencode_config()` + `update_claude_config()` into `update_runtime_configs()`
- `setup-modules/mcp-setup.sh:92-233` — `update_mcp_paths_in_opencode()` → `update_mcp_paths_for_runtime()`
- `setup-modules/agent-deploy.sh:315-399` — `inject_agents_reference()` → iterate registry
- `setup-modules/migrations.sh:627-836` — `clean_deprecated_mcps()`, `validate_opencode_config()` → per-runtime
- `.agents/scripts/shared-constants.sh:1382-1392` — `detect_available_backends()` → use registry
- `.agents/scripts/runner-helper.sh:133-536` — `_detect_backend()`, `_build_dispatch_cmd()` → registry
- `.agents/scripts/headless-runtime-helper.sh` — generalize from OpenCode-only to registry-based
- `.agents/scripts/pulse-wrapper.sh:213,1345-1835` — process detection, session counting
- `.agents/scripts/session-count-helper.sh:116-338` — merge `_count_opencode_sessions()` + `_count_claude_sessions()`
- `.agents/scripts/remote-dispatch-helper.sh:341-597` — runtime detection on remote hosts
- `.agents/scripts/ai-cli-config.sh:124-286` — already well-structured, just needs registry integration
- `.agents/scripts/tool-version-check.sh:73-116` — hardcoded tool entries
- `.agents/scripts/mcp-index-helper.sh:30-565` — reads only `opencode.json`
- `.agents/scripts/mcp-diagnose.sh:71` — hardcoded config path
- `.agents/scripts/worker-sandbox-helper.sh:152-168` — per-runtime config copy
- `.agents/scripts/secret-hygiene-helper.sh:461` — per-runtime config scanning
- `setup-modules/post-setup.sh:142-160` — onboarding dispatch
- `setup-modules/schedulers.sh:153-257` — pulse plist generation
- `setup-modules/tool-install.sh:949-1536` — per-runtime CLI install functions (keep separate but register)

**Files to keep runtime-specific (no migration needed):**
- `.agents/plugins/opencode-aidevops/` — OpenCode plugin API
- `.agents/hooks/git_safety_guard.py` — Claude Code hook API
- `.agents/scripts/extract-opencode-prompts.sh` — binary introspection
- `.agents/scripts/opencode-prompt-drift-check.sh` — upstream tracking
- `.agents/scripts/oauth-pool-helper.sh` Cursor functions — IDE auth extraction
- `setup-modules/tool-install.sh` per-runtime `setup_*_cli()` functions — inherently different

## Acceptance Criteria

- [ ] `runtime-registry.sh` defines 11+ runtimes with all properties (binary, config path, format, MCP root key, command dir, prompt mechanism, session DB, process pattern)
  ```yaml
  verify:
    method: bash
    run: "source ~/.aidevops/agents/scripts/runtime-registry.sh && [[ ${#RUNTIME_IDS[@]} -ge 11 ]]"
  ```
- [ ] `detect_installed_runtimes()` returns only runtimes whose binary is in PATH
  ```yaml
  verify:
    method: bash
    run: "source ~/.aidevops/agents/scripts/runtime-registry.sh && detect_installed_runtimes | head -1"
  ```
- [ ] `register_mcp_for_runtime()` correctly transforms universal MCP definition to OpenCode JSON, Claude CLI, Codex TOML, and Cursor JSON formats
- [ ] MCP command validation: entries with non-existent commands are skipped with a warning (fixes Codex Docker MCP)
- [ ] System prompt deployment works for all installed runtimes via `deploy_prompts_for_runtime()`
- [ ] Unified generator produces identical output to current per-runtime generators (diff test)
- [ ] Adding a hypothetical new runtime requires only: (a) one registry entry, (b) one adapter case, (c) one `setup_*_cli()` function
- [ ] All 45 accidentally-coupled scripts use registry functions instead of hardcoded runtime references
- [ ] `shellcheck` passes on all new/modified scripts
- [ ] Bash 3.2 compatible (no associative arrays, no mapfile, no `${var,,}`)
- [ ] No regression in `aidevops update` — existing OpenCode and Claude Code configs still generated correctly

## Phasing

| Phase | Subtask | Effort | Unblocks |
|-------|---------|--------|----------|
| P0 | t1665.6 Fix Codex Docker MCP + add runtime entries | ~2h | Codex usable immediately |
| P1 | t1665.1 Runtime registry | ~4h | Foundation for all other subtasks |
| P1 | t1665.2 MCP config adapter | ~4h | Universal MCP registration |
| P1 | t1665.3 Prompt injection adapter | ~3h | Universal prompt deployment |
| P2 | t1665.4 Unified generator | ~8h | Eliminates 80% duplication |
| P3 | t1665.5 Migrate coupled scripts | ~6h | Full abstraction |

P0 can be done independently. P1 subtasks can be parallelized. P2 depends on P1. P3 depends on P2.
