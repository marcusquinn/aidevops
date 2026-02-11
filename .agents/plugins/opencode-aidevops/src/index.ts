/**
 * aidevops OpenCode Plugin — Core plugin structure + agent loader
 *
 * Provides native OpenCode integration for the aidevops framework:
 * - Agent loader: scans ~/.aidevops/agents/ and registers agents
 * - Compaction hook: injects framework context during session compaction
 * - Shell env hook: ensures aidevops paths are available in shell commands
 * - Chat context hook: lightweight session-start context injection
 * - CLI tools: exposes aidevops and helper scripts as OpenCode tools
 *
 * @module opencode-aidevops
 */

import { loadConfig } from "./config/schema.js";
import { loadAgents, getAgentSummary } from "./agents/loader.js";
import { createCompactionHook } from "./hooks/compaction.js";
import { createShellEnvHook } from "./hooks/shell-env.js";
import { createChatContextHook } from "./hooks/chat-context.js";
import {
  createAidevopsCliTool,
  createHelperScriptTool,
} from "./tools/aidevops-cli.js";

/** Input provided by OpenCode to the plugin factory */
interface PluginInput {
  directory: string;
  worktree?: string;
  project?: string;
}

/** Hook definitions returned by the plugin */
interface PluginHooks {
  "experimental.session.compacting"?: (
    input: { messages?: unknown[] },
    output: { context: string[] },
  ) => Promise<void>;
  "shell.env"?: () => Record<string, string>;
  "chat.message"?: (
    input: { content?: string; role?: string },
    output: { parts: Array<{ type: string; text: string }> },
  ) => void;
  tool?: Array<{
    name: string;
    description: string;
    parameters: Record<string, unknown>;
    handler: (args: Record<string, unknown>) => Promise<string>;
  }>;
}

/**
 * Main plugin factory function.
 *
 * OpenCode calls this with the current session context. The plugin
 * loads configuration, scans for agents, and returns hook handlers.
 *
 * @param input - Session context from OpenCode (directory, worktree, project)
 * @returns Hook handlers for OpenCode lifecycle events
 */
export async function AidevopsPlugin(
  input: PluginInput,
): Promise<PluginHooks> {
  const { directory } = input;
  const config = loadConfig();

  // Load agents from ~/.aidevops/agents/
  const agents = loadAgents(config);

  // Log agent loading summary (visible in OpenCode debug output)
  if (agents.length > 0) {
    const summary = getAgentSummary(agents);
    // Use stderr so it doesn't interfere with plugin protocol
    process.stderr.write(`[aidevops] ${summary}\n`);
  }

  // Build hooks object based on config
  const hooks: PluginHooks = {};

  // Compaction hook — always enabled (core functionality)
  if (config.hooks.compaction) {
    hooks["experimental.session.compacting"] =
      createCompactionHook(directory);
  }

  // Shell environment hook
  if (config.hooks.shellEnv) {
    hooks["shell.env"] = createShellEnvHook();
  }

  // Chat context hook
  if (config.hooks.chatContext) {
    hooks["chat.message"] = createChatContextHook(directory);
  }

  // Register tools
  hooks.tool = [createAidevopsCliTool(), createHelperScriptTool()];

  return hooks;
}
