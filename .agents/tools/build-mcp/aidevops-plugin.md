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

- **Status**: Implemented (t008, PR #1073)
- **Purpose**: Native OpenCode plugin wrapper for aidevops
- **Approach**: Single-file ESM plugin using hooks-based SDK pattern
- **Location**: `.agents/plugins/opencode-aidevops/index.mjs`
- **SDK**: `@opencode-ai/plugin` v1.1.56+

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
| MCP configs | `opencode.json` mcp section | `generate-opencode-agents.sh` |
| Slash commands | `~/.config/opencode/commands/` | `setup.sh` |
| **Runtime hooks** | Plugin hooks API | **This plugin** |
| **Custom tools** | Plugin tool registration | **This plugin** |
| **Dynamic agents** | Plugin config hook | **This plugin** |
| **Shell environment** | Plugin shell.env hook | **This plugin** |
| **Compaction context** | Plugin compacting hook | **This plugin** |

The plugin only injects agents not already configured by `generate-opencode-agents.sh`, ensuring the shell script always takes precedence.

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

#### 1. Config Hook — Dynamic Agent Loading

Reads all markdown files from `~/.aidevops/agents/` and subdirectories, parses YAML frontmatter, and injects subagent definitions into OpenCode's config. Only injects agents not already configured (shell script takes precedence).

```javascript
// Mutates config.agent to add missing subagents
async function configHook(config) {
  const agents = loadAgentDefinitions();  // ~400 agents from filesystem
  for (const agent of agents) {
    if (config.agent[agent.name]) continue;  // Skip if already configured
    if (agent.mode !== "subagent") continue;  // Only auto-register subagents
    config.agent[agent.name] = {
      description: agent.description,
      mode: "subagent",
    };
  }
}
```

#### 2. Custom Tools

| Tool | Description |
|------|-------------|
| `aidevops` | Run aidevops CLI commands (status, repos, features, etc.) |
| `aidevops_memory_recall` | Search cross-session memory |
| `aidevops_memory_store` | Store new memories |
| `aidevops_pre_edit_check` | Run pre-edit git safety check |

#### 3. Quality Hooks

- **`tool.execute.before`**: Runs ShellCheck on `.sh` files before Write/Edit operations
- **`tool.execute.after`**: Logs git operations for pattern tracking

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
| Phase 4 (oh-my-opencode) skipped | oh-my-opencode is deprecated and actively removed by setup.sh |

## Future Enhancements

### Potential Additions

- **`chat.message` hook**: Intercept user messages for slash command routing
- **`chat.params` hook**: Dynamic model routing based on task complexity
- **`permission.ask` hook**: Auto-approve safe operations, deny dangerous ones
- **`config` hook for MCPs**: Dynamically register MCPs (when SDK supports it natively)
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
