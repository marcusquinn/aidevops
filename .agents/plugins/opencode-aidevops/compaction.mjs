// ---------------------------------------------------------------------------
// Compaction Context
// Extracted from index.mjs (t1914) — context preservation across resets.
// ---------------------------------------------------------------------------

import { existsSync, readFileSync } from "fs";
import { execSync } from "child_process";
import { createHash } from "crypto";
import { join } from "path";

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
 * Run a shell command and return stdout, or empty string on failure.
 * @param {string} cmd
 * @param {number} [timeout=5000]
 * @returns {string}
 */
function run(cmd, timeout = 5000) {
  try {
    return execSync(cmd, {
      encoding: "utf-8",
      timeout,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return "";
  }
}

/**
 * Get current agent state from the mailbox registry.
 * @param {string} workspaceDir
 * @returns {string}
 */
function getAgentState(workspaceDir) {
  const registryPath = join(workspaceDir, "mail", "registry.toon");
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
 * @param {string} directory - Current working directory
 * @returns {string}
 */
function getLoopGuardrails(directory) {
  const loopStateDir = join(directory, ".agent", "loop-state");
  if (!existsSync(loopStateDir)) return "";

  const stateFile = join(loopStateDir, "current.json");
  const content = readIfExists(stateFile);
  if (!content) return "";

  try {
    const state = JSON.parse(content);
    const lines = ["## Loop Guardrails"];

    if (state.task) lines.push(`Task: ${state.task}`);
    if (state.iteration)
      lines.push(
        `Iteration: ${state.iteration}/${state.maxIterations || "\u221e"}`,
      );
    if (state.objective) lines.push(`Objective: ${state.objective}`);
    if (state.constraints && state.constraints.length > 0) {
      lines.push("Constraints:");
      for (const c of state.constraints) {
        lines.push(`- ${c}`);
      }
    }
    if (state.completionCriteria)
      lines.push(`Completion: ${state.completionCriteria}`);

    return lines.join("\n");
  } catch {
    return "";
  }
}

/**
 * Recall relevant memories for the current session context.
 * @param {string} scriptsDir
 * @param {string} directory - Current working directory
 * @returns {string}
 */
function getRelevantMemories(scriptsDir, directory) {
  const memoryHelper = join(scriptsDir, "memory-helper.sh");
  if (!existsSync(memoryHelper)) return "";

  const projectName = directory.split("/").pop() || "";
  const memories = run(
    `bash "${memoryHelper}" recall "${projectName}" --limit 5 2>/dev/null`,
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
    `git -C "${directory}" log --oneline -5 2>/dev/null`,
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
 * Resolve the git repository root for a directory.
 * @param {string} directory
 * @returns {string}
 */
function getGitRoot(directory) {
  return run(`git -C "${directory}" rev-parse --show-toplevel 2>/dev/null`);
}

/**
 * Return the repo-scoped checkpoint path for the active directory.
 *
 * Checkpoints used to be a singleton under tmp/session-checkpoint.md. That
 * allowed a compaction in one repository to replay the previous repository's
 * operational state. Use a hash of the local git root instead so filenames do
 * not disclose private repo names and foreign checkpoints are not considered.
 *
 * @param {string} workspaceDir
 * @param {string} directory
 * @returns {string}
 */
function getScopedCheckpointPath(workspaceDir, directory) {
  const gitRoot = getGitRoot(directory);
  if (!gitRoot) return "";

  const key = createHash("sha256").update(gitRoot).digest("hex").slice(0, 16);
  return join(workspaceDir, "tmp", "session-checkpoints", `repo-${key}.md`);
}

/**
 * Get session checkpoint state if it exists.
 * @param {string} workspaceDir
 * @param {string} directory - Current working directory
 * @returns {string}
 */
function getCheckpointState(workspaceDir, directory) {
  const checkpointFile = getScopedCheckpointPath(workspaceDir, directory);
  if (!checkpointFile) return "";

  const content = readIfExists(checkpointFile);
  if (!content) return "";

  return [
    "## Session Checkpoint",
    "Restore this operational state from the previous session:",
    content,
  ].join("\n");
}

/**
 * Get pending mailbox messages for context continuity.
 * @param {string} scriptsDir
 * @returns {string}
 */
function getMailboxState(scriptsDir) {
  const mailHelper = join(scriptsDir, "mail-helper.sh");
  if (!existsSync(mailHelper)) return "";

  const rawOutput = run(`bash "${mailHelper}" check 2>/dev/null`);
  const pending = parseInt(rawOutput, 10);
  if (isNaN(pending) || pending <= 0) return "";

  return [
    "## Pending Messages",
    `There are ${pending} unread messages in the agent mailbox.`,
    "Check inbox after resuming to handle inter-agent communications.",
  ].join("\n");
}

/**
 * Compaction hook — inject aidevops context into compaction summary.
 * @param {object} deps - { workspaceDir, scriptsDir }
 * @param {object} _input - { sessionID }
 * @param {object} output - { context: string[], prompt?: string }
 * @param {string} directory - Working directory
 */
export async function compactingHook(deps, _input, output, directory) {
  const { workspaceDir, scriptsDir } = deps;

  const sections = [
    getAgentState(workspaceDir),
    getLoopGuardrails(directory),
    getCheckpointState(workspaceDir, directory),
    getRelevantMemories(scriptsDir, directory),
    getGitContext(directory),
    getMailboxState(scriptsDir),
  ].filter(Boolean);

  if (sections.length === 0) return;

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
      "- Security: never expose credentials in output/logs",
      "- Working directory: ~/.aidevops/.agent-workspace/work/[project]/",
      "- Quality: ShellCheck zero violations, SonarCloud A-grade",
      "- ALWAYS Read before Edit/Write — these tools fail without a prior Read",
    ].join("\n"),
  );
}
