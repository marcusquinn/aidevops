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

## Quick Reference

- **Status**: Implemented (t008.1 PR #1138, t008.2 PR #1149, t008.3 PR #1150, t008.4 PR #1157)
- **Purpose**: Native OpenCode plugin wrapper for aidevops
- **Approach**: Single-file ESM plugin using hooks-based SDK pattern
- **Location**: `.agents/plugins/opencode-aidevops/index.mjs`
- **SDK**: `@opencode-ai/plugin` v1.1.56+
- **OMOC Compatibility**: Detects and complements oh-my-opencode when both installed

**Key Decision**: Plugin complements `generate-opencode-agents.sh` — the shell
script handles primary agent config, the plugin adds runtime hooks and tools.

<!-- AI-CONTEXT-END -->

## Overview

The `aidevops-opencode` plugin provides native OpenCode integration for the aidevops framework. It runs as an OpenCode plugin loaded via `file://` protocol and provides dynamic agent loading, custom tools, quality hooks, and compaction context.

### Integration with Existing Setup

aidevops integrates with OpenCode via multiple layers:

| Layer | Mechanism | Managed By |
|-------|-----------|------------|
| Primary agents | `opencode.json` agent section | `generate-opencode-agents.sh` |
| Subagent stubs | `~/.config/opencode/agent/*.md` | `generate-opencode-agents.sh` |
| MCP configs | `opencode.json` mcp section | `generate-opencode-agents.sh` + **This plugin** |
| Slash commands | `~/.config/opencode/commands/` | `setup.sh` |
| **Runtime hooks** | Plugin hooks API | **This plugin** |
| **Custom tools** | Plugin tool registration | **This plugin** |
| **Dynamic agents** | Plugin config hook | **This plugin** |
| **MCP registration** | Plugin config hook (t008.2) | **This plugin** |
| **Shell environment** | Plugin shell.env hook | **This plugin** |
| **Compaction context** | Plugin compacting hook | **This plugin** |

The plugin only injects agents and MCPs not already configured by `generate-opencode-agents.sh`, ensuring the shell script always takes precedence.

## Actual SDK API (v1.1.56)

**Important**: The original design in this document assumed APIs that do not exist (`input.agent.register()`, `input.mcp.register()`, `input.hook.register()`). The actual SDK uses a different pattern:

```typescript
// Plugin signature — function that returns Hooks object
type Plugin = (input: PluginInput) => Promise<Hooks>;

// PluginInput — provided by OpenCode at startup
type PluginInput = {
  client: OpencodeClient;     // API client
  project: Project;           // Project metadata
  directory: string;          // Current working directory
  worktree: string;           // Git worktree root
  serverUrl: URL;             // OpenCode server URL
  $: BunShell;                // Bun shell for running commands
};

// Hooks — returned by the plugin function
interface Hooks {
  config?: (input: Config) => Promise<void>;                    // Mutate OpenCode config
  tool?: { [key: string]: ToolDefinition };                     // Register custom tools
  event?: (input: { event: Event }) => Promise<void>;           // Event listener
  auth?: AuthHook;                                              // Auth provider
  "chat.message"?: (input, output) => Promise<void>;            // Message interception
  "chat.params"?: (input, output) => Promise<void>;             // LLM parameter modification
  "permission.ask"?: (input, output) => Promise<void>;          // Permission handling
  "tool.execute.before"?: (input, output) => Promise<void>;     // Pre-tool hook
  "tool.execute.after"?: (input, output) => Promise<void>;      // Post-tool hook
  "shell.env"?: (input, output) => Promise<void>;               // Shell environment
  "experimental.session.compacting"?: (input, output) => Promise<void>;  // Compaction
}
```

### Key Differences from Original Design

| Original Assumption | Actual SDK |
|---------------------|------------|
| `input.agent.register()` | Use `config` hook to mutate `config.agent` |
| `input.mcp.register()` | Use `config` hook to mutate `config.mcp` |
| `input.hook.register()` | Return hooks as properties of Hooks object |
| `input.tool.register()` | Return tools in `tool` property |
| Class-based plugin | Function-based plugin |
| TypeScript + build step | ESM loaded directly (no build needed) |
| `gray-matter` dependency | Built-in YAML frontmatter parser |

## Current Implementation

### Plugin Structure

```text
.agents/plugins/opencode-aidevops/
├── index.mjs          # Single-file plugin (all hooks and tools)
└── package.json       # Metadata + peer dependency
```

### Hooks Implemented

#### 0. oh-my-opencode Detection (t008.4)

At plugin startup, detects whether oh-my-opencode (OMOC) is installed and active. Detection checks (in order):

1. OpenCode config (`opencode.json`) — looks for `"oh-my-opencode"` in the `plugin` array
2. OMOC config files — `.opencode/oh-my-opencode.json` (project) or `~/.config/opencode/oh-my-opencode.json` (user)
3. npm installation — `npm ls oh-my-opencode`

When OMOC is detected:

| Behaviour | Without OMOC | With OMOC |
|-----------|-------------|-----------|
| context7 MCP | Registered by aidevops | Skipped (OMOC manages it) |
| websearch/grep_app MCPs | N/A (not in aidevops registry) | Left to OMOC |
| Stale OMOC tool patterns | Disabled globally | Left alone (OMOC manages) |
| ShellCheck/secrets hooks | Active | Active (complementary) |
| Comment-checker/todo-enforcer | N/A | OMOC handles |
| Compaction context | Standard | Includes OMOC state |

Results are cached after first detection. The OMOC state is logged at startup and injected into compaction context for session continuity.

#### 1. Config Hook — Dynamic Agent Loading + MCP Registration

The config hook performs two complementary registrations:

**Agent Loading** (t008.1): Reads all markdown files from `~/.aidevops/agents/` and subdirectories, parses YAML frontmatter, and injects subagent definitions into OpenCode's config. Only injects agents not already configured (shell script takes precedence).

**MCP Registration** (t008.2): Registers MCP servers from a data-driven registry, enforces eager/lazy loading policy, and applies per-agent tool permissions. This ensures MCPs are always registered even without re-running `generate-opencode-agents.sh`.

```javascript
async function configHook(config) {
  // Phase 1: Agent registration
  const agents = loadAgentDefinitions();
  for (const agent of agents) {
    if (config.agent[agent.name]) continue;
    if (agent.mode !== "subagent") continue;
    config.agent[agent.name] = { description: agent.description, mode: "subagent" };
  }

  // Phase 2: MCP registration
  registerMcpServers(config);     // Register servers + global tool perms
  applyAgentMcpTools(config);     // Per-agent MCP tool enablement
}
```

**MCP Server Registry**: Data-driven catalog of 12 MCP servers with metadata:

| Field | Purpose |
|-------|---------|
| `name` | MCP server identifier |
| `type` | `"local"` or `"remote"` |
| `command` / `url` | Server launch command or remote URL |
| `eager` | `true` = start at launch, `false` = lazy-load |
| `toolPattern` | Glob pattern for tool permissions (e.g. `"osgrep_*"`) |
| `globallyEnabled` | Whether tools are enabled for all agents |
| `requiresBinary` | Binary that must exist (skips if missing) |
| `macOnly` | Platform restriction flag |

**Registered MCPs**:

| MCP | Type | Loading | Tools Global |
|-----|------|---------|-------------|
| osgrep | local | eager | yes |
| playwriter | local | lazy | yes |
| context7 | remote | lazy | no |
| augment-context-engine | local | lazy | no |
| outscraper | local | lazy | no |
| dataforseo | local | lazy | no |
| shadcn | local | lazy | no |
| claude-code-mcp | local | lazy | no |
| macos-automator | local | lazy | no (macOS) |
| ios-simulator | local | lazy | no (macOS) |
| sentry | remote | lazy | no |
| socket | remote | lazy | no |

**Per-Agent Tool Permissions**: Subagents that need specific MCP tools (e.g. `@dataforseo` needs `dataforseo_*`, `@sentry` needs `sentry_*`) get them enabled via `AGENT_MCP_TOOLS` mapping, applied in `applyAgentMcpTools()`.

#### 2. Custom Tools

| Tool | Description |
|------|-------------|
| `aidevops` | Run aidevops CLI commands (status, repos, features, etc.) |
| `aidevops_memory_recall` | Search cross-session memory |
| `aidevops_memory_store` | Store new memories |
| `aidevops_pre_edit_check` | Run pre-edit git safety check |
| `aidevops_quality_check` | Run quality pipeline on a file or full pre-commit checks |
| `aidevops_install_hooks` | Install/manage git pre-commit quality hooks |

#### 3. Quality Hooks (t008.3)

**Pre-tool hooks** (`tool.execute.before`):

- **Shell scripts (.sh)**: Full quality pipeline matching `pre-commit-hook.sh`:
  - ShellCheck with `-x -S warning` flags
  - Return statement validation (functions must have explicit returns)
  - Positional parameter convention (`local var="$1"` pattern)
  - Secrets pattern scanning (API keys, tokens, private keys)
- **Markdown (.md)**: MD031 (blank lines around code blocks), trailing whitespace
- **All files**: Secrets scanning on Write content (API keys, AWS keys, GitHub tokens, etc.)

**Post-tool hooks** (`tool.execute.after`):

- Git operation detection and logging
- Pattern tracker integration (`pattern-tracker-helper.sh`) for success/failure recording
- ShellCheck/lint run tracking
- File modification audit logging to `~/.aidevops/logs/quality-hooks.log`

#### 4. Shell Environment

Injects into every shell session:

- `PATH` — prepends `~/.aidevops/agents/scripts/`
- `AIDEVOPS_AGENTS_DIR` — path to agents directory
- `AIDEVOPS_WORKSPACE_DIR` — path to agent workspace
- `AIDEVOPS_VERSION` — current framework version

#### 5. Compaction Context

Preserves operational state across context resets:

- Active agent state (mailbox registry)
- Loop guardrails (iteration count, objectives)
- Session checkpoint state
- Relevant memories (project-scoped, limit 5)
- Git context (branch, recent commits)
- Pending mailbox messages

### Design Decisions

| Decision | Rationale |
|----------|-----------|
| Single-file ESM (no build step) | OpenCode loads `file://` ESM directly; avoids TypeScript compilation complexity |
| Zero runtime dependencies | Built-in Node.js APIs + lightweight YAML parser; no `gray-matter` or `zod` needed |
| Complement shell script, don't replace | `generate-opencode-agents.sh` handles primary agent config with full control; plugin adds runtime features |
| Subagents only in config hook | Primary agents need explicit config (model, temperature, tools); auto-registration would override intentional settings |
| Data-driven MCP registry over config file | Plugin needs runtime binary detection and platform-specific logic that a static JSON config cannot express |
| Only osgrep eager-loaded | All other MCPs lazy-load on demand to save ~7K+ tokens on session startup |
| Shell script takes precedence for MCPs | Plugin only registers MCPs not already configured; `generate-opencode-agents.sh` definitions win |
| Complement oh-my-opencode, don't conflict | OMOC detected at startup; shared MCPs (context7) skipped; quality hooks are complementary (no overlap) |

## Future Enhancements

### Potential Additions

- **`chat.message` hook**: Intercept user messages for slash command routing
- **`chat.params` hook**: Dynamic model routing based on task complexity
- **`permission.ask` hook**: Auto-approve safe operations, deny dangerous ones
- **Dynamic agent reloading**: Watch filesystem for agent changes and hot-reload
- **Pattern tracking integration**: Feed tool execution data to `pattern-tracker-helper.sh`

### When to Expand

Expand the plugin when:

1. OpenCode adds new hook types that enable features not possible via shell scripts
2. Users request native tool integrations (memory, pre-edit check) in the tool palette
3. Performance benefits from plugin-level caching become measurable

## References

- [OpenCode Plugin SDK](https://opencode.ai/docs/plugins) — `@opencode-ai/plugin` npm package
- [Plugin types](https://www.npmjs.com/package/@opencode-ai/plugin) — `index.d.ts` for full API
- [aidevops Framework](https://github.com/marcusquinn/aidevops) — source repository
- Implementation: `.agents/plugins/opencode-aidevops/index.mjs`
- Plan: `todo/PLANS.md` section "aidevops-opencode Plugin" (p001)
