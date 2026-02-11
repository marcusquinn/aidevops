/**
 * Type definitions for the opencode-aidevops plugin.
 *
 * These mirror the @opencode-ai/plugin SDK types for the hooks and
 * interfaces used by this plugin. The actual SDK types are provided
 * at runtime by OpenCode.
 */

/** Plugin factory function signature expected by OpenCode */
export declare function AidevopsPlugin(input: PluginInput): Promise<PluginHooks>;

/** Input provided to the plugin factory by OpenCode */
export interface PluginInput {
  /** OpenCode SDK client */
  client?: unknown;
  /** Project name */
  project?: string;
  /** Current working directory */
  directory: string;
  /** Git worktree path (if in a worktree) */
  worktree?: string;
  /** OpenCode server URL */
  serverUrl?: string;
  /** BunShell instance */
  $?: unknown;
}

/** Hook definitions the plugin can return */
export interface PluginHooks {
  /** Inject context during session compaction */
  "experimental.session.compacting"?: (
    input: CompactionInput,
    output: CompactionOutput,
  ) => Promise<void> | void;

  /** Inject environment variables into shell commands */
  "shell.env"?: (
    input: ShellEnvInput,
  ) => Promise<Record<string, string>> | Record<string, string>;

  /** Intercept and modify new user messages */
  "chat.message"?: (
    input: ChatMessageInput,
    output: ChatMessageOutput,
  ) => Promise<void> | void;

  /** Register custom tools */
  tool?: ToolDefinition[];
}

/** Compaction hook input */
export interface CompactionInput {
  messages?: unknown[];
}

/** Compaction hook output — push strings to context[] */
export interface CompactionOutput {
  context: string[];
}

/** Shell environment hook input */
export interface ShellEnvInput {
  command?: string;
  directory?: string;
}

/** Chat message hook input */
export interface ChatMessageInput {
  content?: string;
  role?: string;
}

/** Chat message hook output */
export interface ChatMessageOutput {
  parts: Array<{ type: string; text: string }>;
}

/** Tool definition for registering custom tools */
export interface ToolDefinition {
  name: string;
  description: string;
  parameters: Record<string, ToolParameter>;
  handler: (args: Record<string, unknown>) => Promise<string>;
}

/** Tool parameter schema */
export interface ToolParameter {
  type: string;
  description: string;
  items?: { type: string };
  enum?: string[];
  default?: unknown;
}

/** Agent definition parsed from markdown files */
export interface AgentDefinition {
  /** Agent name (filename without .md) */
  name: string;
  /** Description from YAML frontmatter */
  description: string;
  /** Agent mode: primary or subagent */
  mode: "primary" | "subagent";
  /** Tool permissions from frontmatter */
  tools: Record<string, boolean>;
  /** Model tier hint from frontmatter */
  model?: string;
  /** Markdown content (body after frontmatter) */
  content: string;
  /** Source file path */
  path: string;
  /** Namespace (plugin name or 'core') */
  namespace: string;
}

/** Plugin configuration schema */
export interface PluginConfig {
  /** Path to agents directory */
  agentsDir: string;
  /** Whether to load subagents from subdirectories */
  loadSubagents: boolean;
  /** Agent names to skip loading */
  disabledAgents: string[];
  /** Hook toggles */
  hooks: {
    compaction: boolean;
    shellEnv: boolean;
    chatContext: boolean;
  };
  /** Maximum agents to load (prevents runaway scanning) */
  maxAgents: number;
  /** Directories to skip when scanning */
  excludeDirs: string[];
}
