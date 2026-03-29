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
- **Location**: `.agents/plugins/opencode-aidevops/index.mjs`
- **SDK**: `@opencode-ai/plugin` v1.1.56+
- **Key Decision**: Plugin complements `generate-opencode-agents.sh` — shell script handles primary agent config, plugin adds runtime hooks and tools.

<!-- AI-CONTEXT-END -->

## Integration Layers

| Layer | Mechanism | Managed By |
|-------|-----------|------------|
| Primary agents | `opencode.json` agent section | `generate-opencode-agents.sh` |
| Subagent stubs | `~/.config/opencode/agent/*.md` | `generate-opencode-agents.sh` |
| MCP configs | `opencode.json` mcp section | `generate-opencode-agents.sh` + **This plugin** |
| Slash commands | `~/.config/opencode/commands/` | `setup.sh` |
| Runtime hooks | Plugin hooks API | **This plugin** |
| Custom tools | Plugin tool registration | **This plugin** |
| Dynamic agents | Plugin config hook | **This plugin** |
| MCP registration | Plugin config hook (t008.2) | **This plugin** |
| Shell environment | Plugin shell.env hook | **This plugin** |
| Compaction context | Plugin compacting hook | **This plugin** |

Plugin only injects agents and MCPs not already configured by `generate-opencode-agents.sh` — shell script always takes precedence.

## SDK API (v1.1.56)

```typescript
type Plugin = (input: PluginInput) => Promise<Hooks>;

type PluginInput = {
  client: OpencodeClient;
  project: Project;
  directory: string;        // Current working directory
  worktree: string;         // Git worktree root
  serverUrl: URL;
  $: BunShell;
};

interface Hooks {
  config?: (input: Config) => Promise<void>;
  tool?: { [key: string]: ToolDefinition };
  event?: (input: { event: Event }) => Promise<void>;
  auth?: AuthHook;
  "chat.message"?: (input, output) => Promise<void>;
  "chat.params"?: (input, output) => Promise<void>;
  "permission.ask"?: (input, output) => Promise<void>;
  "tool.execute.before"?: (input, output) => Promise<void>;
  "tool.execute.after"?: (input, output) => Promise<void>;
  "shell.env"?: (input, output) => Promise<void>;
  "experimental.session.compacting"?: (input, output) => Promise<void>;
}
```

## Plugin Structure

```text
.agents/plugins/opencode-aidevops/
├── index.mjs          # Single-file plugin (all hooks and tools)
└── package.json       # Metadata + peer dependency
```

## Hooks Implemented

### 1. Config Hook — Agent Loading + MCP Registration

```javascript
async function configHook(config) {
  const agents = loadAgentDefinitions();
  for (const agent of agents) {
    if (config.agent[agent.name]) continue;
    if (agent.mode !== "subagent") continue;
    config.agent[agent.name] = { description: agent.description, mode: "subagent" };
  }
  registerMcpServers(config);
  applyAgentMcpTools(config);
}
```

**Agent Loading** (t008.1): Reads markdown files from `~/.aidevops/agents/`, parses YAML frontmatter, injects subagent definitions. Skips agents already configured.

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
- [Plugin types](https://www.npmjs.com/package/@opencode-ai/plugin) — `index.d.ts` for full API
- Implementation: `.agents/plugins/opencode-aidevops/index.mjs`
- Plan: `todo/PLANS.md` section "aidevops-opencode Plugin" (p001)
