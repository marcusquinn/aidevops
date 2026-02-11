import { execSync } from "child_process";
import { readFileSync, existsSync, writeFileSync, mkdirSync, unlinkSync } from "fs";
import { join, extname } from "path";
import { homedir, tmpdir } from "os";

const HOME = homedir();
const AGENTS_DIR = join(HOME, ".aidevops", "agents");
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");

/**
 * File extensions and their corresponding quality check commands.
 * Each entry maps an extension to a checker config.
 * @type {Record<string, {cmd: string, args: string[], name: string}>}
 */
const QUALITY_CHECKERS = {
  ".sh": {
    cmd: "shellcheck",
    args: ["-x", "-S", "warning"],
    name: "ShellCheck",
  },
};

/**
 * Run a shell command and return stdout, or empty string on failure.
 * @param {string} cmd
 * @returns {string}
 */
function run(cmd) {
  try {
    return execSync(cmd, {
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return "";
  }
}

/**
 * Read a file if it exists, or return empty string.
 * @param {string} filepath
 * @returns {string}
 */
function readIfExists(filepath) {
  try {
    if (existsSync(filepath)) {
      return readFileSync(filepath, "utf-8").trim();
    }
  } catch {
    // ignore
  }
  return "";
}

/**
 * Get current agent state from registry.toon if it exists.
 * Returns a summary of active agents and their roles.
 * @returns {string}
 */
function getAgentState() {
  const registryPath = join(WORKSPACE_DIR, "mail", "registry.toon");
  const content = readIfExists(registryPath);
  if (!content) return "";

  return [
    "## Active Agent State",
    "The following agents are currently registered in the multi-agent orchestration system:",
    content,
  ].join("\n");
}

/**
 * Get loop guardrails from active loop state.
 * Returns iteration count, objectives, and constraints.
 * @param {string} directory - Current working directory
 * @returns {string}
 */
function getLoopGuardrails(directory) {
  // Check for loop state in the project's .agent directory
  const loopStateDir = join(directory, ".agent", "loop-state");
  if (!existsSync(loopStateDir)) return "";

  const stateFile = join(loopStateDir, "current.json");
  const content = readIfExists(stateFile);
  if (!content) return "";

  try {
    const state = JSON.parse(content);
    const lines = ["## Loop Guardrails"];

    if (state.task) lines.push(`Task: ${state.task}`);
    if (state.iteration) lines.push(`Iteration: ${state.iteration}/${state.maxIterations || "∞"}`);
    if (state.objective) lines.push(`Objective: ${state.objective}`);
    if (state.constraints && state.constraints.length > 0) {
      lines.push("Constraints:");
      for (const c of state.constraints) {
        lines.push(`- ${c}`);
      }
    }
    if (state.completionCriteria) lines.push(`Completion: ${state.completionCriteria}`);

    return lines.join("\n");
  } catch {
    return "";
  }
}

/**
 * Recall relevant memories for the current session context.
 * Uses memory-helper.sh to search for patterns matching recent activity.
 * @param {string} directory - Current working directory
 * @returns {string}
 */
function getRelevantMemories(directory) {
  const memoryHelper = join(SCRIPTS_DIR, "memory-helper.sh");
  if (!existsSync(memoryHelper)) return "";

  // Get the project name from the directory for context-relevant recall
  const projectName = directory.split("/").pop() || "";

  // Recall recent memories related to this project
  const memories = run(
    `bash "${memoryHelper}" recall "${projectName}" --limit 5 2>/dev/null`
  );
  if (!memories) return "";

  return [
    "## Relevant Memories",
    "Previous session learnings relevant to this project:",
    memories,
  ].join("\n");
}

/**
 * Get the current git branch and recent commit context.
 * @param {string} directory
 * @returns {string}
 */
function getGitContext(directory) {
  const branch = run(`git -C "${directory}" branch --show-current 2>/dev/null`);
  if (!branch) return "";

  const recentCommits = run(
    `git -C "${directory}" log --oneline -5 2>/dev/null`
  );

  const lines = ["## Git Context"];
  lines.push(`Branch: ${branch}`);
  if (recentCommits) {
    lines.push("Recent commits:");
    lines.push(recentCommits);
  }

  return lines.join("\n");
}

/**
 * Get pending mailbox messages for context continuity.
 * @returns {string}
 */
function getMailboxState() {
  const inboxDir = join(WORKSPACE_DIR, "mail", "inbox");
  if (!existsSync(inboxDir)) return "";

  const mailHelper = join(SCRIPTS_DIR, "mail-helper.sh");
  if (!existsSync(mailHelper)) return "";

  const rawOutput = run(`bash "${mailHelper}" check 2>/dev/null`);
  // Validate output is a non-negative integer (mail-helper may output TOON blocks)
  const pending = parseInt(rawOutput, 10);
  if (isNaN(pending) || pending <= 0) return "";

  return [
    "## Pending Messages",
    `There are ${pending} unread messages in the agent mailbox.`,
    "Check inbox after resuming to handle inter-agent communications.",
  ].join("\n");
}

/**
 * Check if a quality checker binary is available on the system.
 * Results are cached for the lifetime of the plugin session.
 * @param {string} cmd - The command to check
 * @returns {boolean}
 */
const checkerAvailability = new Map();
function isCheckerAvailable(cmd) {
  if (checkerAvailability.has(cmd)) {
    return checkerAvailability.get(cmd);
  }
  const available = run(`command -v ${cmd} 2>/dev/null`) !== "";
  checkerAvailability.set(cmd, available);
  return available;
}

/**
 * Run a quality checker against file content.
 * Writes content to a temp file, runs the checker, and returns findings.
 * @param {string} filePath - The target file path (for extension detection)
 * @param {string} content - The file content to check (if available)
 * @returns {{ok: boolean, findings: string, checker: string} | null}
 */
function runQualityCheck(filePath, content) {
  const ext = extname(filePath);
  const checker = QUALITY_CHECKERS[ext];
  if (!checker) return null;
  if (!isCheckerAvailable(checker.cmd)) return null;

  // If content is provided, write to a temp file for checking
  // Otherwise check the file in-place (for Edit operations where
  // we don't have the full content upfront)
  let targetPath = filePath;
  let tempFile = null;

  if (content) {
    try {
      const tmpDir = join(tmpdir(), "aidevops-quality-hooks");
      mkdirSync(tmpDir, { recursive: true });
      tempFile = join(tmpDir, `check-${Date.now()}${ext}`);
      writeFileSync(tempFile, content, "utf-8");
      targetPath = tempFile;
    } catch {
      // Fall back to checking the original file path
      targetPath = filePath;
    }
  }

  try {
    const args = checker.args.join(" ");
    execSync(`${checker.cmd} ${args} "${targetPath}"`, {
      encoding: "utf-8",
      timeout: 10000,
      stdio: ["pipe", "pipe", "pipe"],
    });
    return { ok: true, findings: "", checker: checker.name };
  } catch (error) {
    const output = (error.stdout || "") + (error.stderr || "");
    // Replace temp file paths with the original file path in output
    const findings = tempFile
      ? output.replace(new RegExp(tempFile.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g"), filePath)
      : output;
    return { ok: false, findings: findings.trim(), checker: checker.name };
  } finally {
    // Clean up temp file
    if (tempFile) {
      try {
        unlinkSync(tempFile);
      } catch {
        // ignore cleanup failures
      }
    }
  }
}

/**
 * Track files modified in the current session for post-commit reminders.
 * @type {Set<string>}
 */
const modifiedFiles = new Set();

/**
 * Count of modifications since last quality reminder.
 * @type {number}
 */
let modsSinceReminder = 0;

/** Quality reminder threshold — suggest linters-local.sh after this many edits. */
const REMINDER_THRESHOLD = 10;

/**
 * @type {import('@opencode-ai/plugin').Plugin}
 */
export async function AidevopsPlugin({ directory }) {
  /** @type {boolean} */
  const hooksEnabled = (() => {
    const configPath = join(HOME, ".config", "aidevops", "plugin-config.json");
    try {
      if (existsSync(configPath)) {
        const config = JSON.parse(readFileSync(configPath, "utf-8"));
        return config?.hooks?.qualityChecks !== false;
      }
    } catch {
      // ignore parse errors
    }
    return true; // enabled by default
  })();

  return {
    "experimental.preToolUse": async (input) => {
      if (!hooksEnabled) return;

      const { tool, args } = input || {};

      // Only intercept Write and Edit operations
      if (tool !== "Write" && tool !== "Edit") return;

      const filePath = args?.filePath || args?.file_path || "";
      if (!filePath) return;

      // For Write operations, we have the full content
      const content = tool === "Write" ? (args?.content || "") : null;

      const result = runQualityCheck(filePath, content);
      if (!result) return; // No checker for this file type

      if (!result.ok && result.findings) {
        // Return findings as context — don't block the operation
        // The AI agent will see these warnings and can fix issues
        return {
          message: [
            `## ${result.checker} Quality Check`,
            "",
            `Warnings found in \`${filePath}\`:`,
            "",
            "```",
            result.findings,
            "```",
            "",
            "Consider fixing these issues before committing.",
          ].join("\n"),
        };
      }
    },

    "experimental.postToolUse": async (input) => {
      if (!hooksEnabled) return;

      const { tool, args } = input || {};

      // Track file modifications for quality reminders
      if (tool === "Write" || tool === "Edit") {
        const filePath = args?.filePath || args?.file_path || "";
        if (filePath) {
          modifiedFiles.add(filePath);
          modsSinceReminder++;
        }

        // After N modifications, remind about running quality checks
        if (modsSinceReminder >= REMINDER_THRESHOLD) {
          modsSinceReminder = 0;
          const shellFiles = [...modifiedFiles].filter((f) => f.endsWith(".sh"));
          const mdFiles = [...modifiedFiles].filter((f) => f.endsWith(".md"));

          const reminders = [];
          if (shellFiles.length > 0) {
            reminders.push(
              `- ${shellFiles.length} shell script(s) modified — run \`shellcheck -x -S warning\` on them`
            );
          }
          if (mdFiles.length > 0) {
            reminders.push(
              `- ${mdFiles.length} markdown file(s) modified — run \`markdownlint\` on them`
            );
          }
          reminders.push(
            "- Run `linters-local.sh` for a full quality check before committing"
          );

          return {
            message: [
              "## Quality Check Reminder",
              "",
              `You've modified ${modifiedFiles.size} file(s) this session:`,
              "",
              ...reminders,
            ].join("\n"),
          };
        }
      }

      // After Bash tool use with git commit, remind about quality
      if (tool === "Bash") {
        const command = args?.command || "";
        if (command.includes("git commit") && !command.includes("--amend")) {
          const uncheckedShell = [...modifiedFiles].filter(
            (f) => f.endsWith(".sh")
          );
          if (uncheckedShell.length > 0) {
            return {
              message: [
                "## Post-Commit Quality Note",
                "",
                "Shell scripts were modified in this session. If you haven't already,",
                "verify they pass ShellCheck before pushing:",
                "",
                "```bash",
                `shellcheck -x -S warning ${uncheckedShell.map((f) => `"${f}"`).join(" ")}`,
                "```",
              ].join("\n"),
            };
          }
        }
      }
    },

    "experimental.session.compacting": async (_input, output) => {
      // Gather dynamic context that should survive compaction
      const sections = [
        getAgentState(),
        getLoopGuardrails(directory),
        getRelevantMemories(directory),
        getGitContext(directory),
        getMailboxState(),
      ].filter(Boolean);

      if (sections.length === 0) return;

      // Push context that gets appended to the default compaction prompt
      output.context.push(
        [
          "# aidevops Framework Context",
          "Include the following state in your compaction summary so the next session can continue seamlessly:",
          "",
          ...sections,
          "",
          "## Critical Rules to Preserve",
          "- File discovery: use `git ls-files` not Glob",
          "- Git workflow: run pre-edit-check.sh before any file modifications",
          "- Security: credentials only in ~/.config/aidevops/credentials.sh",
          "- Working directory: ~/.aidevops/.agent-workspace/work/[project]/",
          "- Quality: ShellCheck zero violations, SonarCloud A-grade",
        ].join("\n")
      );
    },
  };
}
