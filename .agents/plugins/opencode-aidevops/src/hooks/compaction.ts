import { execSync } from "child_process";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

const HOME = homedir();
const AGENTS_DIR = join(HOME, ".aidevops", "agents");
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");

/**
 * Run a shell command and return stdout, or empty string on failure.
 */
function run(cmd: string): string {
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
 */
function readIfExists(filepath: string): string {
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
 */
function getAgentState(): string {
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
 */
function getLoopGuardrails(directory: string): string {
  const loopStateDir = join(directory, ".agent", "loop-state");
  if (!existsSync(loopStateDir)) return "";

  const stateFile = join(loopStateDir, "current.json");
  const content = readIfExists(stateFile);
  if (!content) return "";

  try {
    const state = JSON.parse(content) as Record<string, unknown>;
    const lines = ["## Loop Guardrails"];

    if (state.task) lines.push(`Task: ${state.task}`);
    if (state.iteration)
      lines.push(
        `Iteration: ${state.iteration}/${(state.maxIterations as string) ?? "inf"}`,
      );
    if (state.objective) lines.push(`Objective: ${state.objective}`);
    if (Array.isArray(state.constraints) && state.constraints.length > 0) {
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
 */
function getRelevantMemories(directory: string): string {
  const memoryHelper = join(SCRIPTS_DIR, "memory-helper.sh");
  if (!existsSync(memoryHelper)) return "";

  const projectName = directory.split("/").pop() ?? "";
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
 */
function getGitContext(directory: string): string {
  const branch = run(
    `git -C "${directory}" branch --show-current 2>/dev/null`,
  );
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
 * Get pending mailbox messages for context continuity.
 */
function getMailboxState(): string {
  const inboxDir = join(WORKSPACE_DIR, "mail", "inbox");
  if (!existsSync(inboxDir)) return "";

  const mailHelper = join(SCRIPTS_DIR, "mail-helper.sh");
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
 * Get session checkpoint if one exists.
 */
function getCheckpointState(): string {
  const checkpointPath = join(
    WORKSPACE_DIR,
    "tmp",
    "session-checkpoint.md",
  );
  const content = readIfExists(checkpointPath);
  if (!content) return "";

  return [
    "## Session Checkpoint",
    "A checkpoint was saved from a previous session:",
    content,
  ].join("\n");
}

/**
 * Create the compaction hook handler.
 * Gathers dynamic context that should survive session compaction.
 */
export function createCompactionHook(directory: string) {
  return async (
    _input: { messages?: unknown[] },
    output: { context: string[] },
  ): Promise<void> => {
    const sections = [
      getAgentState(),
      getLoopGuardrails(directory),
      getRelevantMemories(directory),
      getGitContext(directory),
      getMailboxState(),
      getCheckpointState(),
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
        "- Security: credentials only via `aidevops secret` (gopass) or ~/.config/aidevops/credentials.sh",
        "- Working directory: ~/.aidevops/.agent-workspace/work/[project]/",
        "- Quality: ShellCheck zero violations, SonarCloud A-grade",
        "- Workers: NEVER edit TODO.md (supervisor owns it)",
      ].join("\n"),
    );
  };
}
