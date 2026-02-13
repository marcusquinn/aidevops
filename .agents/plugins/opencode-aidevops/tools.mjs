import { execSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";

/**
 * Create a memory tool (recall or store) using a shared factory pattern.
 * Deduplicates the near-identical memory_recall and memory_store definitions.
 *
 * @param {object} opts
 * @param {string} opts.scriptsDir - Path to scripts directory
 * @param {function} opts.run - Shell command runner
 * @param {string} opts.action - "recall" or "store"
 * @param {string} opts.description - Tool description
 * @param {function} opts.buildArgs - (args, helperPath) => { cmd: string, timeout: number }
 * @returns {object} Tool definition with description and execute method
 */
function createMemoryTool({ scriptsDir, run, action, description, buildArgs }) {
  return {
    description,
    async execute(args) {
      const memoryHelper = join(scriptsDir, "memory-helper.sh");
      if (!existsSync(memoryHelper)) {
        return "Memory system not available (memory-helper.sh not found)";
      }
      const { cmd, timeout } = buildArgs(args, memoryHelper);
      const result = run(cmd, timeout);
      return result || (action === "recall"
        ? "No memories found for this query."
        : "Memory stored successfully.");
    },
  };
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
      const cmd = `aidevops ${args.command || args}`;
      const result = run(cmd, 15000);
      return result || `Command completed: ${cmd}`;
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
        ? ` --loop-mode --task "${args.task}"`
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
 * Run the full pre-commit pipeline via the hook script.
 * @param {string} scriptsDir
 * @returns {string}
 */
function runPreCommitPipeline(scriptsDir) {
  const hookScript = join(scriptsDir, "pre-commit-hook.sh");
  if (!existsSync(hookScript)) {
    return "pre-commit-hook.sh not found — run aidevops update";
  }
  try {
    const result = execSync(`bash "${hookScript}"`, {
      encoding: "utf-8",
      timeout: 30000,
      stdio: ["pipe", "pipe", "pipe"],
    });
    return `Pre-commit quality checks PASSED:\n${result.trim()}`;
  } catch (err) {
    const cmdOutput = (err.stdout || "") + (err.stderr || "");
    return `Pre-commit quality checks FAILED:\n${cmdOutput.trim()}`;
  }
}

/**
 * Format a quality pipeline result into a user-friendly string.
 * @param {string} label
 * @param {{ totalViolations: number, report: string }} result
 * @returns {string}
 */
function formatQualityResult(label, result) {
  return result.totalViolations > 0
    ? `${label}: ${result.totalViolations} issue(s) found:\n${result.report}`
    : `${label}: all checks passed.`;
}

/**
 * Create the quality check tool.
 * @param {string} scriptsDir - Path to scripts directory
 * @param {object} pipelines - { runShellQualityPipeline, runMarkdownQualityPipeline, scanForSecrets }
 * @returns {object} Tool definition
 */
function createQualityCheckTool(scriptsDir, pipelines) {
  const { runShellQualityPipeline, runMarkdownQualityPipeline, scanForSecrets } = pipelines;

  return {
    description:
      'Run quality checks on a file or the full pre-commit pipeline. Args: file (string, path to check) OR command "pre-commit" to run full pipeline on staged files',
    async execute(args) {
      const file = args.file || args.command || args;

      if (file === "pre-commit" || file === "staged") {
        return runPreCommitPipeline(scriptsDir);
      }

      if (typeof file === "string" && file.endsWith(".sh")) {
        return formatQualityResult("Quality check", runShellQualityPipeline(file));
      }

      if (typeof file === "string" && file.endsWith(".md")) {
        return formatQualityResult("Markdown check", runMarkdownQualityPipeline(file));
      }

      if (typeof file === "string" && existsSync(file)) {
        const secretResult = scanForSecrets(file);
        return secretResult.violations > 0
          ? `Secrets scan: ${secretResult.violations} potential issue(s):\n${secretResult.details.join("\n")}`
          : "Secrets scan: no issues found.";
      }

      return `Usage: pass a file path (.sh or .md) or "pre-commit" for full pipeline`;
    },
  };
}

/**
 * Run the install-hooks-helper.sh script.
 * @param {string} helperScript
 * @param {string} action
 * @returns {string}
 */
function runHookHelper(helperScript, action) {
  try {
    const result = execSync(
      `bash "${helperScript}" ${action}`,
      {
        encoding: "utf-8",
        timeout: 15000,
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    return result.trim();
  } catch (err) {
    const cmdOutput = (err.stdout || "") + (err.stderr || "");
    return `Hook ${action} failed:\n${cmdOutput.trim()}`;
  }
}

/**
 * Fallback: install git pre-commit hook directly when helper script is missing.
 * @param {string} scriptsDir
 * @param {function} run - Shell command runner
 * @returns {string}
 */
function installGitHookFallback(scriptsDir, run) {
  const preCommitHook = join(scriptsDir, "pre-commit-hook.sh");
  if (!existsSync(preCommitHook)) {
    return "pre-commit-hook.sh not found — run aidevops update";
  }
  const gitHookDir = run("git rev-parse --git-dir 2>/dev/null");
  if (!gitHookDir) {
    return "Not in a git repository — cannot install pre-commit hook";
  }
  const hookDest = join(gitHookDir, "hooks", "pre-commit");
  try {
    execSync(`cp "${preCommitHook}" "${hookDest}" && chmod +x "${hookDest}"`, {
      encoding: "utf-8",
      timeout: 5000,
    });
    return `Git pre-commit hook installed at ${hookDest}`;
  } catch (err) {
    return `Failed to install hook: ${err.message}`;
  }
}

/**
 * Create the install hooks tool.
 * @param {string} scriptsDir - Path to scripts directory
 * @param {function} run - Shell command runner
 * @returns {object} Tool definition
 */
function createInstallHooksTool(scriptsDir, run) {
  return {
    description:
      'Install or manage git pre-commit quality hooks. Args: action (string: "install", "uninstall", "status", "test")',
    async execute(args) {
      const action = args.action || args || "install";
      const helperScript = join(scriptsDir, "install-hooks-helper.sh");

      if (existsSync(helperScript)) {
        return runHookHelper(helperScript, action);
      }

      if (action === "install") {
        return installGitHookFallback(scriptsDir, run);
      }

      return `install-hooks-helper.sh not found. Available actions: install, uninstall, status, test`;
    },
  };
}

/**
 * Create all tool definitions for the plugin.
 *
 * NOTE: opencode 1.1.56+ uses Zod v4 to validate tool args schemas.
 * Plain `{ type: "string" }` objects are NOT valid Zod schemas and cause:
 *   TypeError: undefined is not an object (evaluating 'schema._zod.def')
 * Fix: omit `args` entirely and document parameters in `description`.
 * The LLM passes args as a plain object; we extract fields defensively.
 *
 * @param {string} scriptsDir - Path to scripts directory
 * @param {function} run - Shell command runner
 * @param {object} pipelines - Quality pipeline functions
 * @param {function} pipelines.runShellQualityPipeline
 * @param {function} pipelines.runMarkdownQualityPipeline
 * @param {function} pipelines.scanForSecrets
 * @returns {Record<string, object>}
 */
export function createTools(scriptsDir, run, pipelines) {
  return {
    aidevops: createAidevopsTool(run),

    aidevops_memory_recall: createMemoryTool({
      scriptsDir,
      run,
      action: "recall",
      description:
        'Recall memories from the aidevops cross-session memory system. Args: query (string), limit (string, default "5")',
      buildArgs: (args, helper) => ({
        cmd: `bash "${helper}" recall "${args.query}" --limit ${args.limit || "5"} 2>/dev/null`,
        timeout: 10000,
      }),
    }),

    aidevops_memory_store: createMemoryTool({
      scriptsDir,
      run,
      action: "store",
      description:
        'Store a new memory in the aidevops cross-session memory. Args: content (string), confidence (string: low/medium/high, default "medium")',
      buildArgs: (args, helper) => ({
        cmd: `bash "${helper}" store "${args.content}" --confidence ${args.confidence || "medium"} 2>/dev/null`,
        timeout: 10000,
      }),
    }),

    aidevops_pre_edit_check: createPreEditCheckTool(scriptsDir),
    aidevops_quality_check: createQualityCheckTool(scriptsDir, pipelines),
    aidevops_install_hooks: createInstallHooksTool(scriptsDir, run),
  };
}
