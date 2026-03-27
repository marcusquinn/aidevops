import { execSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";

/**
 * Escape a string for safe interpolation into a shell command.
 * Wraps in single quotes and escapes any internal single quotes.
 * @param {string} str
 * @returns {string}
 */
function shellEscape(str) {
  return "'" + String(str).replace(/'/g, "'\\''") + "'";
}

/**
 * Validate that a CLI command string contains only safe characters.
 * Allows alphanumeric, spaces, hyphens, underscores, dots, forward slashes,
 * colons, hash signs (#), and at-signs (@) — sufficient for all aidevops subcommands and file path arguments.
 * Rejects shell metacharacters ($, `, ;, |, &, (, ), etc.).
 * @param {string} command
 * @returns {boolean}
 */
function isSafeCommand(command) {
  return /^[a-zA-Z0-9 _\-./:#@]+$/.test(command);
}

/**
 * Create the aidevops CLI tool.
 * @param {function} run - Shell command runner
 * @returns {object} Tool definition
 */
function createAidevopsTool(run) {
  return {
    description:
      'Run aidevops CLI commands (status, repos, features, secret, etc.). Pass command as string e.g. "status", "repos", "features"',
    async execute(args) {
      const rawCmd = String(args.command || args);
      if (!isSafeCommand(rawCmd)) {
        return `Error: command contains disallowed characters. Only alphanumeric, spaces, hyphens, underscores, dots, slashes, colons, # and @ are permitted.`;
      }
      const cmd = `aidevops ${rawCmd}`;
      const result = run(cmd, 15000);
      return result || `Command completed: ${cmd}`;
    },
  };
}

/**
 * Create the unified memory tool (recall and store in one tool).
 *
 * Consolidates the former aidevops_memory_recall and aidevops_memory_store tools.
 * Both operations share the same helper script and execution pattern — a single
 * tool with an action discriminator is cleaner for the LLM and reduces tool count.
 *
 * @param {string} scriptsDir - Path to scripts directory
 * @param {function} run - Shell command runner
 * @returns {object} Tool definition
 */
function createMemoryTool(scriptsDir, run) {
  return {
    description:
      'Recall or store memories in the aidevops cross-session memory system. ' +
      'Args: action ("recall"|"store"), query (string, for recall), ' +
      'limit (string, default "5", for recall), ' +
      'content (string, for store), confidence ("low"|"medium"|"high", default "medium", for store)',
    async execute(args) {
      const memoryHelper = join(scriptsDir, "memory-helper.sh");
      if (!existsSync(memoryHelper)) {
        return "Memory system not available (memory-helper.sh not found)";
      }

      const action = String(args.action || "recall");

      if (action === "recall") {
        const query = args.query || "";
        const limit = args.limit || "5";
        const cmd = `bash "${memoryHelper}" recall ${shellEscape(query)} --limit ${shellEscape(limit)}`;
        const result = run(cmd, 10000);
        return result || "No memories found for this query.";
      }

      if (action === "store") {
        const content = typeof args.content === "string" ? args.content.trim() : "";
        if (!content) {
          return "Error: content is required to store a memory";
        }
        const confidence = args.confidence || "medium";
        const cmd = `bash "${memoryHelper}" store ${shellEscape(content)} --confidence ${shellEscape(confidence)}`;
        const result = run(cmd, 10000);
        return result || "Memory stored successfully.";
      }

      return `Unknown action: ${action}. Use "recall" or "store".`;
    },
  };
}

/**
 * Create the pre-edit check tool.
 * @param {string} scriptsDir - Path to scripts directory
 * @returns {object} Tool definition
 */
function createPreEditCheckTool(scriptsDir) {
  const PRE_EDIT_GUIDANCE = {
    1: "STOP — you are on main/master branch. Create a worktree first.",
    2: "Create a worktree before proceeding with edits.",
    3: "WARNING — proceed with caution.",
  };

  return {
    description:
      'Run the pre-edit git safety check before modifying files. Returns exit code and guidance. Args: task (optional string for loop mode)',
    async execute(args) {
      const script = join(scriptsDir, "pre-edit-check.sh");
      if (!existsSync(script)) {
        return "pre-edit-check.sh not found — cannot verify git safety";
      }
      const taskFlag = args.task
        ? ` --loop-mode --task ${shellEscape(args.task)}`
        : "";
      try {
        const result = execSync(`bash "${script}"${taskFlag}`, {
          encoding: "utf-8",
          timeout: 10000,
          stdio: ["pipe", "pipe", "pipe"],
        });
        return `Pre-edit check PASSED (exit 0):\n${result.trim()}`;
      } catch (err) {
        const code = err.status || 1;
        const cmdOutput = (err.stdout || "") + (err.stderr || "");
        return `Pre-edit check exit ${code}: ${PRE_EDIT_GUIDANCE[code] || "Unknown"}\n${cmdOutput.trim()}`;
      }
    },
  };
}

/**
 * Create all tool definitions for the plugin.
 *
 * Tools (4 total):
 *   - aidevops              — aidevops CLI runner
 *   - aidevops_memory       — unified recall/store (merged from former recall + store pair)
 *   - aidevops_pre_edit_check — git safety check before file edits
 *   - model-accounts-pool   — OAuth account pool management (added in index.mjs)
 *
 * NOTE: aidevops_quality_check was removed. Quality checks run automatically
 * via the tool.execute.before hook on every Write/Edit operation — an explicit
 * LLM-callable tool is redundant and adds unnecessary context overhead.
 *
 * NOTE: aidevops_install_hooks was removed. Hook installation is a one-time
 * setup operation best done via Bash: `bash ~/.aidevops/agents/scripts/install-hooks-helper.sh install`
 * or `aidevops security posture`. A dedicated plugin tool adds ~90 lines of
 * code for a task the LLM can perform directly via the Bash tool.
 *
 * NOTE: opencode 1.1.56+ uses Zod v4 to validate tool args schemas.
 * Plain `{ type: "string" }` objects are NOT valid Zod schemas and cause:
 *   TypeError: undefined is not an object (evaluating 'schema._zod.def')
 * Fix: omit `args` entirely and document parameters in `description`.
 * The LLM passes args as a plain object; we extract fields defensively.
 *
 * @param {string} scriptsDir - Path to scripts directory
 * @param {function} run - Shell command runner
 * @param {object} _pipelines - Quality pipeline functions (unused — kept for API compatibility)
 * @returns {Record<string, object>}
 */
export function createTools(scriptsDir, run, _pipelines) {
  return {
    aidevops: createAidevopsTool(run),
    aidevops_memory: createMemoryTool(scriptsDir, run),
    aidevops_pre_edit_check: createPreEditCheckTool(scriptsDir),
  };
}
