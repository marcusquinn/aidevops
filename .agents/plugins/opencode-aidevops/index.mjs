import { execSync } from "child_process";
import { readFileSync, existsSync, readdirSync, writeFileSync, mkdirSync } from "fs";
import { join, resolve, extname } from "path";
import { homedir } from "os";
import { tmpdir } from "os";

const HOME = homedir();
const AGENTS_DIR = join(HOME, ".aidevops", "agents");
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");
const MCP_OVERRIDES_PATH = join(HOME, ".config", "aidevops", "mcp-overrides.json");

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

  const projectName = directory.split("/").pop() || "";

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
      if (entries[name]) continue;
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
  if (existsSync(join(directory, "configs", "mcp-templates"))) {
    return directory;
  }

  const mainRepo = join(HOME, "Git", "aidevops");
  if (existsSync(join(mainRepo, "configs", "mcp-templates"))) {
    return mainRepo;
  }

  const deployedConfigs = join(HOME, ".aidevops", "configs");
  if (existsSync(join(deployedConfigs, "mcp-templates"))) {
    return join(HOME, ".aidevops");
  }

  return null;
}

// ── oh-my-opencode Compatibility (t008.4) ─────────────────────────────

/**
 * Known oh-my-opencode MCP server names that overlap with aidevops defaults.
 * When both plugins are active, aidevops defers to OMOC for these to avoid
 * duplicate registrations.
 * @type {Set<string>}
 */
const OMOC_KNOWN_MCPS = new Set([
  "exa",
  "context7",
  "grep-app",
]);

/**
 * Known oh-my-opencode hook event names that overlap with aidevops hooks.
 * @type {Set<string>}
 */
const OMOC_KNOWN_HOOKS = new Set([
  "comment-checker",
  "todo-continuation-enforcer",
]);

/**
 * Detect whether oh-my-opencode is installed and active as an OpenCode plugin.
 * Checks multiple locations in priority order:
 * 1. OpenCode config plugin array
 * 2. npm/bun global or local install
 * 3. .opencode/plugins/ directory
 * @param {string} directory - Current working directory
 * @returns {{ installed: boolean, version: string|null, configPath: string|null }}
 */
function detectOhMyOpencode(directory) {
  const result = { installed: false, version: null, configPath: null };

  // 1. Check OpenCode config for oh-my-opencode in plugin array
  const configLocations = [
    join(directory, "opencode.json"),
    join(directory, "opencode.jsonc"),
    join(directory, ".opencode", "opencode.json"),
    join(HOME, ".config", "opencode", "opencode.json"),
  ];

  for (const configPath of configLocations) {
    const config = readJson(configPath);
    if (!config?.plugin) continue;

    const plugins = Array.isArray(config.plugin) ? config.plugin : [];
    if (plugins.includes("oh-my-opencode")) {
      result.installed = true;
      result.configPath = configPath;
      break;
    }
  }

  // 2. Check for oh-my-opencode config file (indicates active usage)
  if (!result.installed) {
    const omocConfigs = [
      join(directory, ".opencode", "oh-my-opencode.json"),
      join(HOME, ".config", "opencode", "oh-my-opencode.json"),
    ];
    for (const omocPath of omocConfigs) {
      if (existsSync(omocPath)) {
        result.installed = true;
        result.configPath = omocPath;
        break;
      }
    }
  }

  // 3. Try to get version from npm/bun
  if (result.installed) {
    const version = run("npm list -g oh-my-opencode --depth=0 --json 2>/dev/null");
    if (version) {
      try {
        const parsed = JSON.parse(version);
        result.version = parsed?.dependencies?.["oh-my-opencode"]?.version || null;
      } catch {
        // ignore
      }
    }
  }

  return result;
}

/**
 * Load oh-my-opencode configuration to understand what it provides.
 * Returns the parsed config or null if not found/parseable.
 * @param {string} directory - Current working directory
 * @returns {object|null}
 */
function loadOmocConfig(directory) {
  const paths = [
    join(directory, ".opencode", "oh-my-opencode.json"),
    join(HOME, ".config", "opencode", "oh-my-opencode.json"),
  ];

  for (const p of paths) {
    const config = readJson(p);
    if (config) return config;
  }

  return null;
}

/**
 * Get the set of MCP server names that oh-my-opencode is managing.
 * Combines known defaults with any user-configured MCPs from OMOC config.
 * @param {object|null} omocConfig - Parsed oh-my-opencode config
 * @returns {Set<string>}
 */
function getOmocManagedMcps(omocConfig) {
  const managed = new Set(OMOC_KNOWN_MCPS);

  if (omocConfig?.mcpServers && typeof omocConfig.mcpServers === "object") {
    for (const name of Object.keys(omocConfig.mcpServers)) {
      managed.add(name);
    }
  }

  // Also check the mcp key (some OMOC versions use this)
  if (omocConfig?.mcp && typeof omocConfig.mcp === "object") {
    for (const name of Object.keys(omocConfig.mcp)) {
      managed.add(name);
    }
  }

  return managed;
}

/**
 * Check which oh-my-opencode hooks are disabled by the user.
 * @param {object|null} omocConfig - Parsed oh-my-opencode config
 * @returns {Set<string>}
 */
function getOmocDisabledHooks(omocConfig) {
  const disabled = new Set();

  if (Array.isArray(omocConfig?.disabled_hooks)) {
    for (const hook of omocConfig.disabled_hooks) {
      disabled.add(hook);
    }
  }

  return disabled;
}

/**
 * Filter aidevops MCP entries to avoid duplicating MCPs already managed by OMOC.
 * @param {Record<string, object>} entries - aidevops MCP registry entries
 * @param {Set<string>} omocMcps - MCP names managed by oh-my-opencode
 * @returns {{ filtered: Record<string, object>, deduped: string[] }}
 */
function deduplicateMcps(entries, omocMcps) {
  const filtered = {};
  const deduped = [];

  for (const [name, config] of Object.entries(entries)) {
    if (omocMcps.has(name)) {
      deduped.push(name);
      continue;
    }
    filtered[name] = config;
  }

  return { filtered, deduped };
}

// ── Quality Hooks ─────────────────────────────────────────────────────

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
    const findings = tempFile
      ? output.replace(new RegExp(tempFile.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g"), filePath)
      : output;
    return { ok: false, findings: findings.trim(), checker: checker.name };
  } finally {
    if (tempFile) {
      try {
        execSync(`rm -f "${tempFile}"`, { stdio: "pipe" });
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

  // Detect oh-my-opencode presence
  const omoc = detectOhMyOpencode(directory);
  const omocConfig = omoc.installed ? loadOmocConfig(directory) : null;
  const omocMcps = omoc.installed ? getOmocManagedMcps(omocConfig) : new Set();
  const omocDisabledHooks = omoc.installed ? getOmocDisabledHooks(omocConfig) : new Set();

  // Log compatibility state at startup
  if (omoc.installed) {
    const ver = omoc.version ? ` v${omoc.version}` : "";
    console.error(
      `[aidevops] oh-my-opencode${ver} detected — running in compatibility mode. ` +
      `Deferring ${omocMcps.size} MCP(s) to OMOC.`
    );
  }

  // Determine if quality hooks should be active.
  // If OMOC provides its own comment-checker or similar hooks, we skip
  // overlapping functionality but keep aidevops-specific checks (ShellCheck).
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
    return true;
  })();

  return {
    // Register MCPs via the config hook — deduplicate with OMOC
    config: async (config) => {
      if (!mcpRegistry || Object.keys(mcpRegistry.entries).length === 0) return;

      if (!config.mcp) {
        config.mcp = {};
      }

      // If OMOC is active, filter out MCPs it already manages
      let entriesToRegister = mcpRegistry.entries;
      if (omoc.installed && omocMcps.size > 0) {
        const { filtered, deduped } = deduplicateMcps(mcpRegistry.entries, omocMcps);
        entriesToRegister = filtered;
        if (deduped.length > 0) {
          console.error(
            `[aidevops] Skipped ${deduped.length} MCP(s) already managed by oh-my-opencode: ${deduped.join(", ")}`
          );
        }
      }

      // Merge registry entries — user's existing config takes priority
      for (const [name, mcpConfig] of Object.entries(entriesToRegister)) {
        if (config.mcp[name]) continue;
        config.mcp[name] = mcpConfig;
      }
    },

    // PreToolUse: quality checks on Write/Edit (ShellCheck for .sh files)
    // This does NOT overlap with OMOC's comment-checker or todo-enforcer —
    // those are agent-behaviour hooks, not file-quality hooks.
    "experimental.preToolUse": async (input) => {
      if (!hooksEnabled) return;

      const { tool, args } = input || {};

      if (tool !== "Write" && tool !== "Edit") return;

      const filePath = args?.filePath || args?.file_path || "";
      if (!filePath) return;

      const content = tool === "Write" ? (args?.content || "") : null;

      const result = runQualityCheck(filePath, content);
      if (!result) return;

      if (!result.ok && result.findings) {
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

    // PostToolUse: track modifications and remind about quality checks
    "experimental.postToolUse": async (input) => {
      if (!hooksEnabled) return;

      const { tool, args } = input || {};

      if (tool === "Write" || tool === "Edit") {
        const filePath = args?.filePath || args?.file_path || "";
        if (filePath) {
          modifiedFiles.add(filePath);
          modsSinceReminder++;
        }

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

      // After git commit, remind about unchecked shell scripts
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

    // Compaction hook: inject aidevops context into compaction summaries
    "experimental.session.compacting": async (_input, output) => {
      const sections = [
        getAgentState(),
        getLoopGuardrails(directory),
        getRelevantMemories(directory),
        getGitContext(directory),
        getMailboxState(),
      ].filter(Boolean);

      // Add OMOC compatibility state to compaction context
      if (omoc.installed) {
        sections.push([
          "## oh-my-opencode Compatibility",
          `oh-my-opencode is active${omoc.version ? ` (v${omoc.version})` : ""}.`,
          "aidevops is running in compatibility mode — MCP deduplication is active.",
          "Do not remove oh-my-opencode from the plugin list.",
        ].join("\n"));
      }

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
          "- Security: credentials only in ~/.config/aidevops/credentials.sh",
          "- Working directory: ~/.aidevops/.agent-workspace/work/[project]/",
          "- Quality: ShellCheck zero violations, SonarCloud A-grade",
        ].join("\n")
      );
    },
  };
}
