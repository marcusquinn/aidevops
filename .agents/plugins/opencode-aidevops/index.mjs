import { execSync } from "child_process";
import { readFileSync, existsSync, readdirSync } from "fs";
import { join, resolve } from "path";
import { homedir } from "os";

const HOME = homedir();
const AGENTS_DIR = join(HOME, ".aidevops", "agents");
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");
const MCP_OVERRIDES_PATH = join(HOME, ".config", "aidevops", "mcp-overrides.json");

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

// ── MCP Registry ──────────────────────────────────────────────────────

/**
 * Read and parse a JSON file. Returns null on any error.
 * @param {string} filepath
 * @returns {object|null}
 */
function readJson(filepath) {
  try {
    if (!existsSync(filepath)) return null;
    return JSON.parse(readFileSync(filepath, "utf-8"));
  } catch {
    return null;
  }
}

/**
 * Check if an MCP config contains placeholder values needing user configuration.
 * @param {object} config
 * @returns {boolean}
 */
function hasPlaceholders(config) {
  const check = (val) =>
    /YOUR_.*_HERE|REPLACE_ME|<.*>|\/Users\/YOU\//i.test(val);

  if (config.type === "local" && Array.isArray(config.command)) {
    if (config.command.some(check)) return true;
  }
  const env = config.environment || config.env;
  if (env && typeof env === "object") {
    if (Object.values(env).some(check)) return true;
  }
  if (config.headers && typeof config.headers === "object") {
    if (Object.values(config.headers).some(check)) return true;
  }
  return false;
}

/**
 * Extract OpenCode MCP configs from a template file's "opencode" section.
 * @param {object} json - Parsed template JSON
 * @returns {Record<string, object>}
 */
function extractFromTemplate(json) {
  const result = {};
  const opencode = json.opencode;
  if (!opencode || typeof opencode !== "object") return result;

  for (const [key, value] of Object.entries(opencode)) {
    if (key.startsWith("_")) continue;
    if (typeof value !== "object" || value === null) continue;

    if (value.type === "remote" && typeof value.url === "string") {
      result[key] = {
        type: "remote",
        url: value.url,
        enabled: value.enabled !== false,
        ...(value.headers ? { headers: value.headers } : {}),
      };
    } else if (Array.isArray(value.command)) {
      const entry = {
        type: "local",
        command: value.command,
        enabled: value.enabled !== false,
      };
      if (value.environment && typeof value.environment === "object") {
        entry.environment = value.environment;
      }
      result[key] = entry;
    }
  }

  return result;
}

/**
 * Normalise a legacy mcpServers entry into OpenCode format.
 * @param {object} raw
 * @returns {object|null}
 */
function normaliseLegacyEntry(raw) {
  if (raw.type === "remote" && typeof raw.url === "string") {
    return {
      type: "remote",
      url: raw.url,
      enabled: raw.enabled !== false,
      ...(raw.headers ? { headers: raw.headers } : {}),
    };
  }

  const cmd = raw.command;
  const args = Array.isArray(raw.args) ? raw.args : [];

  if (typeof cmd === "string") {
    const entry = {
      type: "local",
      command: [cmd, ...args],
      enabled: raw.enabled !== false,
    };
    const env = raw.env || raw.environment;
    if (env && typeof env === "object") {
      entry.environment = env;
    }
    return entry;
  }

  if (Array.isArray(cmd)) {
    const entry = {
      type: "local",
      command: cmd,
      enabled: raw.enabled !== false,
    };
    const env = raw.env || raw.environment;
    if (env && typeof env === "object") {
      entry.environment = env;
    }
    return entry;
  }

  return null;
}

/**
 * Load all MCP configurations from template files and legacy config.
 * @param {string} repoRoot - Path to the aidevops repo root
 * @returns {{ entries: Record<string, object>, errors: Array<{name: string, reason: string}> }}
 */
function loadMcpRegistry(repoRoot) {
  const entries = {};
  const errors = [];

  // 1. Load from template files
  const templatesDir = join(repoRoot, "configs", "mcp-templates");
  try {
    const files = readdirSync(templatesDir).filter((f) => f.endsWith(".json"));
    for (const file of files) {
      const json = readJson(join(templatesDir, file));
      if (!json) {
        errors.push({ name: file, reason: "Failed to parse JSON" });
        continue;
      }
      const extracted = extractFromTemplate(json);
      for (const [name, config] of Object.entries(extracted)) {
        if (hasPlaceholders(config)) {
          config.enabled = false;
        }
        entries[name] = config;
      }
    }
  } catch {
    errors.push({ name: "mcp-templates/", reason: "Directory not found" });
  }

  // 2. Load from legacy config (lower priority)
  const legacyPath = join(repoRoot, "configs", "mcp-servers-config.json.txt");
  const legacy = readJson(legacyPath);
  if (legacy?.mcpServers && typeof legacy.mcpServers === "object") {
    for (const [name, raw] of Object.entries(legacy.mcpServers)) {
      if (entries[name]) continue; // Template takes priority
      const config = normaliseLegacyEntry(raw);
      if (config) {
        if (hasPlaceholders(config)) {
          config.enabled = false;
        }
        entries[name] = config;
      } else {
        errors.push({ name, reason: "Could not normalise legacy config" });
      }
    }
  }

  // 3. Apply user overrides (highest priority)
  const overrides = readJson(MCP_OVERRIDES_PATH);
  if (overrides && typeof overrides === "object") {
    for (const [name, raw] of Object.entries(overrides)) {
      if (typeof raw !== "object" || raw === null) continue;
      if (raw.enabled === false) {
        if (entries[name]) entries[name].enabled = false;
        continue;
      }
      const config = normaliseLegacyEntry(raw);
      if (config) entries[name] = config;
    }
  }

  return { entries, errors };
}

/**
 * Find the aidevops repo root by walking up from the deployed agents directory
 * or from the current working directory.
 * @param {string} directory - Current working directory
 * @returns {string|null}
 */
function findRepoRoot(directory) {
  // Check if we're in the aidevops repo itself
  if (existsSync(join(directory, "configs", "mcp-templates"))) {
    return directory;
  }

  // Check the main repo location
  const mainRepo = join(HOME, "Git", "aidevops");
  if (existsSync(join(mainRepo, "configs", "mcp-templates"))) {
    return mainRepo;
  }

  // Check deployed location (setup.sh copies configs)
  const deployedConfigs = join(HOME, ".aidevops", "configs");
  if (existsSync(join(deployedConfigs, "mcp-templates"))) {
    return join(HOME, ".aidevops");
  }

  return null;
}

// ── Plugin Entry Point ────────────────────────────────────────────────

/**
 * @type {import('@opencode-ai/plugin').Plugin}
 */
export async function AidevopsPlugin({ directory }) {
  // Load MCP registry at plugin startup
  const repoRoot = findRepoRoot(directory);
  let mcpRegistry = null;
  if (repoRoot) {
    mcpRegistry = loadMcpRegistry(repoRoot);
  }

  return {
    // Register MCPs via the config hook
    config: async (config) => {
      if (!mcpRegistry || Object.keys(mcpRegistry.entries).length === 0) return;

      // Initialise mcp section if absent
      if (!config.mcp) {
        config.mcp = {};
      }

      // Merge registry entries — user's existing config takes priority
      for (const [name, mcpConfig] of Object.entries(mcpRegistry.entries)) {
        if (config.mcp[name]) continue; // Don't overwrite user's existing config
        config.mcp[name] = mcpConfig;
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
