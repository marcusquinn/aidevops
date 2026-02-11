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

- **Status**: Design phase (not yet implemented)
- **Purpose**: Native OpenCode plugin wrapper for aidevops
- **Approach**: Thin wrapper that loads existing aidevops agents/MCPs
- **Compatibility**: Works with OpenCode plugin system

**Key Decision**: aidevops is built for OpenCode (TUI, Desktop, Extension).
The plugin provides additional OpenCode-specific enhancements.

<!-- AI-CONTEXT-END -->

## Overview

This document outlines the architecture for an optional `aidevops-opencode` plugin that would provide native OpenCode integration for the aidevops framework.

### Current State

aidevops currently integrates with OpenCode via:

1. **Markdown agents** deployed to `~/.config/opencode/agent/`
2. **JSON MCP configs** in `~/.config/opencode/opencode.json`
3. **Slash commands** in `~/.config/opencode/commands/`
4. **Shell scripts** for helper operations

### Proposed Plugin Benefits

| Benefit | Description |
|---------|-------------|
| **Cleaner Installation** | `npm install aidevops-opencode` vs running setup.sh |
| **Lifecycle Hooks** | Pre-commit quality checks, auto-formatting |
| **Dynamic Agent Loading** | Load agents from `~/.aidevops/agents/` at runtime |
| **MCP Registration** | Register aidevops MCPs programmatically |
| **Version Management** | Automatic updates via npm |

## Architecture Design

### Plugin Structure

```text
aidevops-opencode/
├── src/
│   ├── index.ts              # Main plugin entry
│   ├── agents/
│   │   ├── loader.ts         # Load agents from ~/.aidevops/agents/
│   │   └── registry.ts       # Register agents with OpenCode
│   ├── mcps/
│   │   ├── loader.ts         # Load MCP configs
│   │   └── registry.ts       # Register MCPs with OpenCode
│   ├── hooks/
│   │   ├── pre-commit.ts     # Quality checks before commit
│   │   ├── post-tool-use.ts  # After tool execution
│   │   └── user-prompt.ts    # Prompt preprocessing
│   ├── tools/
│   │   └── aidevops-cli.ts   # Expose aidevops CLI as tool
│   └── config/
│       ├── schema.ts         # Zod config schema
│       └── types.ts          # TypeScript types
├── package.json
├── tsconfig.json
└── README.md
```

### Core Components

#### 1. Agent Loader

```typescript
// src/agents/loader.ts
import { readdir, readFile } from 'fs/promises';
import { join } from 'path';
import { homedir } from 'os';
import matter from 'gray-matter';

interface AgentDefinition {
  name: string;
  description: string;
  mode: 'primary' | 'subagent';
  tools: Record<string, boolean>;
  content: string;
}

export async function loadAgents(): Promise<AgentDefinition[]> {
  const agentsDir = join(homedir(), '.aidevops', 'agents');
  const agents: AgentDefinition[] = [];
  
  // Load main agents (*.md in root)
  const mainAgents = await loadAgentsFromDir(agentsDir, 'primary');
  agents.push(...mainAgents);
  
  // Load subagents from subdirectories
  const subdirs = ['aidevops', 'wordpress', 'seo', 'tools', 'services', 'workflows'];
  for (const subdir of subdirs) {
    const subAgents = await loadAgentsFromDir(join(agentsDir, subdir), 'subagent');
    agents.push(...subAgents);
  }
  
  return agents;
}

async function loadAgentsFromDir(dir: string, mode: 'primary' | 'subagent'): Promise<AgentDefinition[]> {
  const files = await readdir(dir).catch(() => []);
  const agents: AgentDefinition[] = [];
  
  for (const file of files) {
    if (!file.endsWith('.md')) continue;
    
    const content = await readFile(join(dir, file), 'utf-8');
    const { data, content: body } = matter(content);
    
    agents.push({
      name: file.replace('.md', ''),
      description: data.description || '',
      mode: data.mode || mode,
      tools: data.tools || {},
      content: body,
    });
  }
  
  return agents;
}
```

#### 2. MCP Registry

```typescript
// src/mcps/registry.ts
import type { PluginInput } from '@opencode-ai/plugin';

interface MCPConfig {
  name: string;
  type: 'local' | 'remote';
  command: string[];
  env?: Record<string, string>;
  enabled: boolean;
}

export function registerMCPs(input: PluginInput, mcps: MCPConfig[]) {
  for (const mcp of mcps) {
    input.mcp.register({
      name: mcp.name,
      type: mcp.type,
      command: mcp.command,
      environment: mcp.env,
      enabled: mcp.enabled,
    });
  }
}

// Default aidevops MCPs
export const defaultMCPs: MCPConfig[] = [
  {
    name: 'context7',
    type: 'local',
    command: ['npx', '-y', '@context7/mcp@latest'],
    enabled: true,
  },
  {
    name: 'augment-context-engine',
    type: 'local',
    command: ['auggie', '--mcp'],
    enabled: true,
  },
  {
    name: 'repomix',
    type: 'local',
    command: ['npx', '-y', 'repomix@latest', '--mcp'],
    enabled: true,
  },
  // ... more MCPs
];
```

#### 3. Quality Hooks

```typescript
// src/hooks/pre-commit.ts
import type { PluginInput, HookResult } from '@opencode-ai/plugin';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

export function createPreCommitHook(input: PluginInput) {
  return {
    event: 'PreToolUse',
    matcher: /^(Write|Edit)$/,
    async handler(context: any): Promise<HookResult> {
      const { tool, args } = context;
      
      // Skip if not a shell script
      if (!args.filePath?.endsWith('.sh')) {
        return { continue: true };
      }
      
      // Run ShellCheck
      try {
        await execAsync(`shellcheck "${args.filePath}"`);
      } catch (error: any) {
        return {
          continue: true,
          message: `ShellCheck warnings:\n${error.stdout}`,
        };
      }
      
      return { continue: true };
    },
  };
}
```

#### 4. Main Plugin Entry

```typescript
// src/index.ts
import type { Plugin, PluginInput } from '@opencode-ai/plugin';
import { loadAgents } from './agents/loader';
import { registerMCPs, defaultMCPs } from './mcps/registry';
import { createPreCommitHook } from './hooks/pre-commit';
import { loadConfig } from './config/schema';

export default function aidevopsPlugin(): Plugin {
  return {
    name: 'aidevops-opencode',
    version: '1.0.0',
    
    async setup(input: PluginInput) {
      const config = await loadConfig();
      
      // Load and register agents from ~/.aidevops/agents/
      const agents = await loadAgents();
      for (const agent of agents) {
        input.agent.register({
          name: agent.name,
          description: agent.description,
          mode: agent.mode,
          tools: agent.tools,
          prompt: agent.content,
        });
      }
      
      // Register MCPs
      const mcps = config.mcps ?? defaultMCPs;
      registerMCPs(input, mcps);
      
      // Register hooks
      if (config.hooks?.preCommit !== false) {
        input.hook.register(createPreCommitHook(input));
      }
      
      // Register aidevops CLI as a tool
      input.tool.register({
        name: 'aidevops',
        description: 'Run aidevops CLI commands',
        parameters: {
          command: { type: 'string', description: 'Command to run' },
          args: { type: 'array', items: { type: 'string' } },
        },
        async handler({ command, args }) {
          const { exec } = await import('child_process');
          const { promisify } = await import('util');
          const execAsync = promisify(exec);
          
          const result = await execAsync(`aidevops ${command} ${args.join(' ')}`);
          return result.stdout;
        },
      });
    },
  };
}
```

### Configuration Schema

```typescript
// src/config/schema.ts
import { z } from 'zod';
import { readFile } from 'fs/promises';
import { join } from 'path';
import { homedir } from 'os';

const configSchema = z.object({
  // Agent loading
  agentsDir: z.string().default('~/.aidevops/agents'),
  loadSubagents: z.boolean().default(true),
  disabledAgents: z.array(z.string()).default([]),
  
  // MCP configuration
  mcps: z.array(z.object({
    name: z.string(),
    type: z.enum(['local', 'remote']),
    command: z.array(z.string()),
    env: z.record(z.string()).optional(),
    enabled: z.boolean().default(true),
  })).optional(),
  disabledMcps: z.array(z.string()).default([]),
  
  // Hooks
  hooks: z.object({
    preCommit: z.boolean().default(true),
    postToolUse: z.boolean().default(true),
    qualityCheck: z.boolean().default(true),
  }).default({}),
  
});

export type Config = z.infer<typeof configSchema>;

export async function loadConfig(): Promise<Config> {
  const configPath = join(homedir(), '.config', 'opencode', 'aidevops-opencode.json');
  
  try {
    const content = await readFile(configPath, 'utf-8');
    return configSchema.parse(JSON.parse(content));
  } catch {
    return configSchema.parse({});
  }
}
```

### Package Configuration

```json
{
  "name": "aidevops-opencode",
  "version": "1.0.0",
  "description": "OpenCode plugin for aidevops framework",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "type": "module",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "import": "./dist/index.js"
    }
  },
  "scripts": {
    "build": "bun build src/index.ts --outdir dist --target bun --format esm && tsc --emitDeclarationOnly",
    "typecheck": "tsc --noEmit"
  },
  "keywords": ["opencode", "plugin", "aidevops", "devops", "agents"],
  "author": "Marcus Quinn",
  "license": "MIT",
  "dependencies": {
    "@opencode-ai/plugin": "^1.0.162",
    "gray-matter": "^4.0.3",
    "zod": "^4.1.8"
  },
  "devDependencies": {
    "bun-types": "latest",
    "typescript": "^5.7.3"
  },
  "peerDependencies": {
    "opencode": ">=1.0.150"
  }
}
```

## Implementation Roadmap

### Phase 1: Core Plugin (MVP)

- [ ] Basic plugin structure
- [ ] Agent loader from `~/.aidevops/agents/`
- [ ] MCP registration
- [ ] aidevops CLI tool

### Phase 2: Hooks

- [ ] Pre-commit quality checks (ShellCheck)
- [ ] Post-tool-use logging
- [ ] Quality check reminders

### Phase 3: Enhanced Features

- [ ] Dynamic agent reloading
- [ ] MCP health monitoring
- [ ] Integration with aidevops update system

### Phase 4: oh-my-opencode Compatibility (t008.4)

- [x] Detect OMOC presence (OpenCode config, OMOC config files, npm)
- [x] Deduplicate MCP registrations (skip MCPs managed by OMOC)
- [x] Complement hooks without overlap (ShellCheck vs comment-checker)
- [x] Inject OMOC state into compaction context
- [x] Make setup.sh OMOC-aware (skip cleanup when plugin handles coexistence)

#### Design Decisions

**Coexistence over replacement**: When both `opencode-aidevops` and `oh-my-opencode` are installed, the plugin runs in compatibility mode rather than requiring the user to choose one. This is because:

1. OMOC provides agent orchestration (Sisyphus, background agents, magic keywords)
2. aidevops provides framework integration (memory, mailbox, supervisor, quality gates)
3. The overlap is limited to MCP registration and some hook events

**MCP deduplication strategy**: aidevops defers to OMOC for shared MCPs (exa, context7, grep-app) since OMOC may have user-customised versions. aidevops-specific MCPs (augment-context-engine, repomix, etc.) are registered normally.

**Hook complementarity**: OMOC hooks (comment-checker, todo-continuation-enforcer) operate at the agent-behaviour level. aidevops hooks (ShellCheck PreToolUse, quality reminders) operate at the file-quality level. No overlap — both run simultaneously.

**Detection approach**: Checks OpenCode config `plugin` array and OMOC config file existence. Does NOT check npm global install alone (OMOC could be installed but not configured as a plugin).

## Decision: Plugin vs Current Approach

### Keep Current Approach (Recommended for Now)

| Aspect | Current | Plugin |
|--------|---------|--------|
| **Scope** | Full framework (agents, scripts) | OpenCode plugin API |
| **Flexibility** | High (markdown agents) | Medium (TypeScript) |
| **Maintenance** | Shell scripts | TypeScript + npm |
| **Installation** | setup.sh | npm install |
| **Updates** | git pull + setup.sh | npm update |

**Recommendation**: Continue with current approach, but design plugin for future.

### When to Build Plugin

Build the plugin when:

1. OpenCode becomes dominant AI CLI tool
2. Users request native plugin experience
3. Hooks become essential (quality gates, etc.)

## References

- [OpenCode Plugin SDK](https://opencode.ai/docs/plugins)
- [aidevops Framework](https://github.com/marcusquinn/aidevops)
