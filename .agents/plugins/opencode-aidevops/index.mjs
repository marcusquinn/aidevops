import { execSync } from "child_process";
import { readFileSync, readdirSync, existsSync, statSync } from "fs";
import { join, relative, basename } from "path";
import { homedir } from "os";

const HOME = homedir();
const AGENTS_DIR = join(HOME, ".aidevops", "agents");
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

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
 * Parse YAML frontmatter from a markdown file.
 * Lightweight parser — no dependencies. Handles the common cases.
 * @param {string} content
 * @returns {{ data: Record<string, any>, body: string }}
 */
function parseFrontmatter(content) {
  const match = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) return { data: {}, body: content };

  const yaml = match[1];
  const body = match[2];
  const data = {};

  for (const line of yaml.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const colonIdx = trimmed.indexOf(":");
    if (colonIdx === -1) continue;

    const key = trimmed.slice(0, colonIdx).trim();
    let value = trimmed.slice(colonIdx + 1).trim();

    // Handle booleans and numbers
    if (value === "true") value = true;
    else if (value === "false") value = false;
    else if (/^\d+(\.\d+)?$/.test(value)) value = Number(value);

    data[key] = value;
  }

  return { data, body };
}

// ---------------------------------------------------------------------------
// Phase 1: Agent Loader
// ---------------------------------------------------------------------------

/**
 * Load agent definitions from ~/.aidevops/agents/ by reading markdown files
 * and parsing their YAML frontmatter.
 * @returns {Array<{name: string, description: string, mode: string, relPath: string}>}
 */
function loadAgentDefinitions() {
  if (!existsSync(AGENTS_DIR)) return [];

  const agents = [];

  // Load primary agents (root *.md files)
  try {
    const rootFiles = readdirSync(AGENTS_DIR).filter(
      (f) =>
        f.endsWith(".md") &&
        !f.startsWith("AGENTS") &&
        !f.startsWith("SKILL") &&
        !f.startsWith("README"),
    );

    for (const file of rootFiles) {
      const filepath = join(AGENTS_DIR, file);
      if (!statSync(filepath).isFile()) continue;

      const content = readIfExists(filepath);
      if (!content) continue;

      const { data } = parseFrontmatter(content);
      agents.push({
        name: basename(file, ".md"),
        description: data.description || "",
        mode: data.mode || "primary",
        relPath: file,
      });
    }
  } catch {
    // ignore read errors
  }

  // Load subagents from known subdirectories
  const subdirs = [
    "aidevops",
    "content",
    "seo",
    "tools",
    "services",
    "workflows",
    "memory",
    "custom",
    "draft",
  ];

  for (const subdir of subdirs) {
    const dirPath = join(AGENTS_DIR, subdir);
    if (!existsSync(dirPath)) continue;

    try {
      loadAgentsRecursive(dirPath, subdir, agents);
    } catch {
      // ignore
    }
  }

  return agents;
}

/**
 * Recursively load agent markdown files from a directory.
 * @param {string} dirPath
 * @param {string} relBase
 * @param {Array} agents
 */
function loadAgentsRecursive(dirPath, relBase, agents) {
  let entries;
  try {
    entries = readdirSync(dirPath, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    const fullPath = join(dirPath, entry.name);

    if (entry.isDirectory()) {
      // Skip references/ and node_modules/
      if (entry.name === "references" || entry.name === "node_modules") {
        continue;
      }
      loadAgentsRecursive(fullPath, join(relBase, entry.name), agents);
    } else if (
      entry.isFile() &&
      entry.name.endsWith(".md") &&
      !entry.name.startsWith("README") &&
      !entry.name.endsWith("-skill.md")
    ) {
      const content = readIfExists(fullPath);
      if (!content) continue;

      const { data } = parseFrontmatter(content);
      agents.push({
        name: basename(entry.name, ".md"),
        description: data.description || "",
        mode: data.mode || "subagent",
        relPath: join(relBase, entry.name),
      });
    }
  }
}

// ---------------------------------------------------------------------------
// Phase 2: Config Hook — inject agents and MCPs into OpenCode config
// ---------------------------------------------------------------------------

/**
 * Modify OpenCode config to register aidevops agents dynamically.
 * This complements generate-opencode-agents.sh by ensuring agents are
 * always up-to-date even without re-running setup.sh.
 * @param {object} config - OpenCode Config object (mutable)
 */
async function configHook(config) {
  // Ensure agent section exists
  if (!config.agent) config.agent = {};

  // Load agent definitions and register any that aren't already configured
  const agents = loadAgentDefinitions();
  let injected = 0;

  for (const agent of agents) {
    // Skip if already configured (generate-opencode-agents.sh takes precedence)
    if (config.agent[agent.name]) continue;

    // Only auto-register subagents — primary agents need explicit config
    if (agent.mode !== "subagent") continue;

    config.agent[agent.name] = {
      description: agent.description || `aidevops subagent: ${agent.relPath}`,
      mode: "subagent",
    };
    injected++;
  }

  if (injected > 0) {
    // Log for debugging (visible in OpenCode logs)
    console.error(
      `[aidevops] Config hook: injected ${injected} subagent definitions`,
    );
  }
}

// ---------------------------------------------------------------------------
// Phase 3: Quality Hooks
// ---------------------------------------------------------------------------

/**
 * Pre-tool-use hook: ShellCheck gate for Write/Edit on .sh files.
 * Runs ShellCheck before the tool executes and adds warnings to output.
 * @param {object} input - { tool, sessionID, callID }
 * @param {object} output - { args } (mutable)
 */
async function toolExecuteBefore(input, output) {
  const { tool } = input;

  // Only intercept Write and Edit tools
  if (tool !== "Write" && tool !== "Edit" && tool !== "write" && tool !== "edit")
    return;

  // Check if the target file is a shell script
  const filePath = output.args?.filePath || output.args?.file_path || "";
  if (!filePath.endsWith(".sh")) return;

  // Run ShellCheck if available
  const result = run(
    `shellcheck -x -S warning "${filePath}" 2>&1`,
    10000,
  );

  if (result) {
    // ShellCheck found issues — log them (they'll appear in tool output)
    console.error(`[aidevops] ShellCheck warnings for ${filePath}:\n${result}`);
  }
}

/**
 * Post-tool-use hook: Log tool execution for debugging and pattern tracking.
 * @param {object} input - { tool, sessionID, callID }
 * @param {object} output - { title, output, metadata } (mutable)
 */
async function toolExecuteAfter(input, output) {
  // Lightweight logging — only for shell commands that modify files
  if (input.tool !== "Bash" && input.tool !== "bash") return;

  // Check if this was a git commit (for pattern tracking)
  const title = output.title || "";
  if (title.includes("git commit") || title.includes("git push")) {
    // Could integrate with pattern-tracker-helper.sh here
    // For now, just log
    console.error(`[aidevops] Git operation detected: ${title}`);
  }
}

// ---------------------------------------------------------------------------
// Phase 4: Shell Environment
// ---------------------------------------------------------------------------

/**
 * Inject aidevops environment variables into shell sessions.
 * @param {object} _input - { cwd }
 * @param {object} output - { env } (mutable)
 */
async function shellEnvHook(_input, output) {
  // Ensure aidevops scripts are on PATH
  if (existsSync(SCRIPTS_DIR)) {
    const currentPath = output.env.PATH || process.env.PATH || "";
    if (!currentPath.includes(SCRIPTS_DIR)) {
      output.env.PATH = `${SCRIPTS_DIR}:${currentPath}`;
    }
  }

  // Set aidevops workspace directory
  output.env.AIDEVOPS_AGENTS_DIR = AGENTS_DIR;
  output.env.AIDEVOPS_WORKSPACE_DIR = WORKSPACE_DIR;

  // Set aidevops version if available
  const version = readIfExists(join(AGENTS_DIR, "..", "version"));
  if (version) {
    output.env.AIDEVOPS_VERSION = version;
  }
}

// ---------------------------------------------------------------------------
// Compaction Context (existing feature, improved)
// ---------------------------------------------------------------------------

/**
 * Get current agent state from the mailbox registry.
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
 * @param {string} directory - Current working directory
 * @returns {string}
 */
function getRelevantMemories(directory) {
  const memoryHelper = join(SCRIPTS_DIR, "memory-helper.sh");
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
 * Get session checkpoint state if it exists.
 * @returns {string}
 */
function getCheckpointState() {
  const checkpointFile = join(
    WORKSPACE_DIR,
    "tmp",
    "session-checkpoint.md",
  );
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
 * @returns {string}
 */
function getMailboxState() {
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
 * Compaction hook — inject aidevops context into compaction summary.
 * @param {object} _input - { sessionID }
 * @param {object} output - { context: string[], prompt?: string }
 * @param {string} directory - Working directory
 */
async function compactingHook(_input, output, directory) {
  const sections = [
    getAgentState(),
    getLoopGuardrails(directory),
    getCheckpointState(),
    getRelevantMemories(directory),
    getGitContext(directory),
    getMailboxState(),
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

// ---------------------------------------------------------------------------
// Tool Definitions
// ---------------------------------------------------------------------------

/**
 * Create tool definitions for the plugin.
 *
 * NOTE: opencode 1.1.56+ uses Zod v4 to validate tool args schemas.
 * Plain `{ type: "string" }` objects are NOT valid Zod schemas and cause:
 *   TypeError: undefined is not an object (evaluating 'schema._zod.def')
 * Fix: omit `args` entirely and document parameters in `description`.
 * The LLM passes args as a plain object; we extract fields defensively.
 *
 * @returns {Record<string, object>}
 */
function createTools() {
  return {
    aidevops: {
      description:
        'Run aidevops CLI commands (status, repos, features, secret, etc.). Pass command as string e.g. "status", "repos", "features"',
      async execute(args) {
        const cmd = `aidevops ${args.command || args}`;
        const result = run(cmd, 15000);
        return result || `Command completed: ${cmd}`;
      },
    },

    aidevops_memory_recall: {
      description:
        'Recall memories from the aidevops cross-session memory system. Args: query (string), limit (string, default "5")',
      async execute(args) {
        const memoryHelper = join(SCRIPTS_DIR, "memory-helper.sh");
        if (!existsSync(memoryHelper)) {
          return "Memory system not available (memory-helper.sh not found)";
        }
        const limit = args.limit || "5";
        const result = run(
          `bash "${memoryHelper}" recall "${args.query}" --limit ${limit} 2>/dev/null`,
          10000,
        );
        return result || "No memories found for this query.";
      },
    },

    aidevops_memory_store: {
      description:
        'Store a new memory in the aidevops cross-session memory. Args: content (string), confidence (string: low/medium/high, default "medium")',
      async execute(args) {
        const memoryHelper = join(SCRIPTS_DIR, "memory-helper.sh");
        if (!existsSync(memoryHelper)) {
          return "Memory system not available (memory-helper.sh not found)";
        }
        const confidence = args.confidence || "medium";
        const result = run(
          `bash "${memoryHelper}" store "${args.content}" --confidence ${confidence} 2>/dev/null`,
          10000,
        );
        return result || "Memory stored successfully.";
      },
    },

    aidevops_pre_edit_check: {
      description:
        'Run the pre-edit git safety check before modifying files. Returns exit code and guidance. Args: task (optional string for loop mode)',
      async execute(args) {
        const script = join(SCRIPTS_DIR, "pre-edit-check.sh");
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
          const output = (err.stdout || "") + (err.stderr || "");
          const guidance = {
            1: "STOP — you are on main/master branch. Create a worktree first.",
            2: "Create a worktree before proceeding with edits.",
            3: "WARNING — proceed with caution.",
          };
          return `Pre-edit check exit ${code}: ${guidance[code] || "Unknown"}\n${output.trim()}`;
        }
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Main Plugin Export
// ---------------------------------------------------------------------------

/**
 * aidevops OpenCode Plugin
 *
 * Provides:
 * 1. Config hook — dynamic agent loading from ~/.aidevops/agents/
 * 2. Custom tools — aidevops CLI, memory recall/store, pre-edit check
 * 3. Quality hooks — ShellCheck gate on .sh file edits
 * 4. Shell environment — aidevops paths and variables
 * 5. Compaction context — preserves operational state across context resets
 *
 * @type {import('@opencode-ai/plugin').Plugin}
 */
export async function AidevopsPlugin({ directory }) {
  return {
    // Phase 1+2: Dynamic agent and config injection
    config: async (config) => configHook(config),

    // Phase 1: Custom tools
    tool: createTools(),

    // Phase 3: Quality hooks
    "tool.execute.before": toolExecuteBefore,
    "tool.execute.after": toolExecuteAfter,

    // Phase 4: Shell environment
    "shell.env": shellEnvHook,

    // Compaction context (existing + improved)
    "experimental.session.compacting": async (input, output) =>
      compactingHook(input, output, directory),
  };
}
