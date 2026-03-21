import { execSync } from "child_process";
import {
  readFileSync,
  existsSync,
  appendFileSync,
  mkdirSync,
  statSync,
  writeFileSync,
  renameSync,
} from "fs";
import { join } from "path";
import { homedir, platform } from "os";
import { createTools } from "./tools.mjs";
import { initObservability, handleEvent, recordToolCall } from "./observability.mjs";
import { loadAgentIndex, applyAgentMcpTools } from "./agent-loader.mjs";
import { validateReturnStatements, validatePositionalParams } from "./validators.mjs";
import { runMarkdownQualityPipeline } from "./quality-pipeline.mjs";
import { createTtsrHooks } from "./ttsr.mjs";
import { createPoolAuthHook, createOpenAIPoolAuthHook, createCursorPoolAuthHook, createPoolTool, initPoolAuth, registerPoolProvider } from "./oauth-pool.mjs";
import { createProviderAuthHook } from "./provider-auth.mjs";

const HOME = homedir();
const AGENTS_DIR = join(HOME, ".aidevops", "agents");
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");
const LOGS_DIR = join(HOME, ".aidevops", "logs");
const QUALITY_LOG = join(LOGS_DIR, "quality-hooks.log");
const QUALITY_DETAIL_LOG = join(LOGS_DIR, "quality-details.log");
const QUALITY_DETAIL_MAX_BYTES = 2 * 1024 * 1024; // 2 MB
const CONSOLE_MAX_DETAIL_LINES = 10;
const IS_MACOS = platform() === "darwin";

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

// ---------------------------------------------------------------------------
// Phase 1: Lightweight Agent Discovery (t1040)
// ---------------------------------------------------------------------------
// Previously scanned 500+ .md files at startup (readFileSync + parseFrontmatter
// each), causing TUI display glitches and slow launches.
//
// Strategy (cheapest first):
//   1. Read subagent-index.toon (1 file, ~177 lines) — pre-built index
//   2. Fallback: directory-only scan (readdirSync for filenames, no file reads)
//
// The index is manually maintained in the repo. The fallback ensures new agents
// are still discoverable even if the index is stale or missing.

// Agent index loading extracted to agent-loader.mjs

// ---------------------------------------------------------------------------
// Phase 2: MCP Server Registry + Config Hook
// ---------------------------------------------------------------------------

/**
 * Resolve the package runner command (bun x preferred, npx fallback).
 * Cached after first call.
 * @returns {string}
 */
let _pkgRunner = null;
function getPkgRunner() {
  if (_pkgRunner !== null) return _pkgRunner;
  const bunPath = run("which bun");
  const npxPath = run("which npx");
  _pkgRunner = bunPath ? `${bunPath} x` : npxPath || "npx";
  return _pkgRunner;
}

/**
 * MCP Server Registry — canonical catalog of all known MCP servers.
 *
 * Each entry defines:
 *   - command: Array of command + args for local MCPs
 *   - url: URL for remote MCPs (mutually exclusive with command)
 *   - type: "local" (default) or "remote"
 *   - eager: true = start at launch, false = lazy-load on demand
 *   - toolPattern: glob pattern for tool permissions (e.g. "playwriter_*")
 *   - globallyEnabled: whether tools are enabled globally (true) or per-agent (false)
 *   - requiresBinary: optional binary name that must exist for local MCPs
 *   - macOnly: optional flag for macOS-only MCPs
 *   - description: human-readable description for logging
 *
 * This mirrors the Python definitions in generate-opencode-agents.sh but
 * runs at plugin load time, ensuring MCPs are registered even without
 * re-running setup.sh.
 *
 * @returns {Array<object>}
 */
function getMcpRegistry() {
  const pkgRunner = getPkgRunner();
  const pkgRunnerParts = pkgRunner.split(" ");

  return [
    // --- Lazy-loaded MCPs (start on demand) ---
    {
      name: "playwriter",
      type: "local",
      command: [...pkgRunnerParts, "playwriter@latest"],
      eager: false,
      toolPattern: "playwriter_*",
      globallyEnabled: true,
      description: "Browser automation via Chrome extension",
    },
    {
      name: "augment-context-engine",
      type: "local",
      command: ["auggie", "--mcp"],
      eager: false,
      toolPattern: "augment-context-engine_*",
      globallyEnabled: false,
      requiresBinary: "auggie",
      description: "Semantic codebase search (Augment)",
    },
    {
      name: "context7",
      type: "remote",
      url: "https://mcp.context7.com/mcp",
      eager: false,
      toolPattern: "context7_*",
      globallyEnabled: false,
      description: "Library documentation lookup",
    },
    {
      name: "outscraper",
      type: "local",
      command: [
        "/bin/bash",
        "-c",
        "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server",
      ],
      eager: false,
      toolPattern: "outscraper_*",
      globallyEnabled: false,
      description: "Business intelligence extraction",
    },
    {
      name: "dataforseo",
      type: "local",
      command: [
        "/bin/bash",
        "-c",
        `source ~/.config/aidevops/credentials.sh && DATAFORSEO_USERNAME=$DATAFORSEO_USERNAME DATAFORSEO_PASSWORD=$DATAFORSEO_PASSWORD ${pkgRunner} dataforseo-mcp-server`,
      ],
      eager: false,
      toolPattern: "dataforseo_*",
      globallyEnabled: false,
      description: "Comprehensive SEO data",
    },
    {
      name: "shadcn",
      type: "local",
      command: ["npx", "shadcn@latest", "mcp"],
      eager: false,
      toolPattern: "shadcn_*",
      globallyEnabled: false,
      description: "UI component library",
    },
    {
      name: "claude-code-mcp",
      type: "local",
      command: ["npx", "-y", "github:marcusquinn/claude-code-mcp"],
      eager: false,
      toolPattern: "claude-code-mcp_*",
      globallyEnabled: false,
      alwaysOverwrite: true,
      description: "Claude Code one-shot execution",
    },
    {
      name: "macos-automator",
      type: "local",
      command: ["npx", "-y", "@steipete/macos-automator-mcp@0.2.0"],
      eager: false,
      toolPattern: "macos-automator_*",
      globallyEnabled: false,
      macOnly: true,
      description: "AppleScript and JXA automation",
    },
    {
      name: "ios-simulator",
      type: "local",
      command: ["npx", "-y", "ios-simulator-mcp"],
      eager: false,
      toolPattern: "ios-simulator_*",
      globallyEnabled: false,
      macOnly: true,
      description: "iOS Simulator interaction",
    },
    {
      name: "sentry",
      type: "remote",
      url: "https://mcp.sentry.dev/mcp",
      eager: false,
      toolPattern: "sentry_*",
      globallyEnabled: false,
      description: "Error tracking (requires OAuth)",
    },
    {
      name: "socket",
      type: "remote",
      url: "https://mcp.socket.dev/",
      eager: false,
      toolPattern: "socket_*",
      globallyEnabled: false,
      description: "Dependency security scanning",
    },
  ];
}

/**
 * Check if an MCP entry should be skipped (wrong platform, missing binary).
 * @param {object} mcp - MCP registry entry
 * @param {object} tools - Config tools object (mutable — disables pattern if binary missing)
 * @returns {boolean} true if the MCP should be skipped
 */
function shouldSkipMcp(mcp, tools) {
  if (mcp.macOnly && !IS_MACOS) return true;

  if (mcp.requiresBinary) {
    const binaryPath = run(`which ${mcp.requiresBinary}`);
    if (!binaryPath) {
      if (mcp.toolPattern) tools[mcp.toolPattern] = false;
      return true;
    }
  }

  return false;
}

/**
 * Build the MCP config entry (remote or local).
 * @param {object} mcp - MCP registry entry
 * @returns {object} Config entry for config.mcp[name]
 */
function buildMcpConfigEntry(mcp) {
  if (mcp.type === "remote" && mcp.url) {
    return { type: "remote", url: mcp.url, enabled: mcp.eager };
  }
  return { type: "local", command: mcp.command, enabled: mcp.eager };
}

/**
 * Register a single MCP server in the config. Returns true if newly registered.
 * @param {object} mcp - MCP registry entry
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {boolean} Whether a new registration was made
 */
function registerSingleMcp(mcp, config) {
  if (!config.mcp[mcp.name] || mcp.alwaysOverwrite) {
    config.mcp[mcp.name] = buildMcpConfigEntry(mcp);
    return true;
  }

  // Respect explicit enabled:false from worker configs (t221).
  if (config.mcp[mcp.name].enabled === undefined) {
    config.mcp[mcp.name].enabled = mcp.eager;
  }
  return false;
}

/**
 * Set global tool permissions for an MCP, respecting worker config overrides.
 * @param {object} mcp - MCP registry entry
 * @param {object} tools - Config tools object (mutable)
 */
function applyMcpToolPermissions(mcp, tools) {
  if (!mcp.toolPattern) return;
  if (tools[mcp.toolPattern] !== false) {
    tools[mcp.toolPattern] = mcp.globallyEnabled;
  }
}

/**
 * Register MCP servers in the OpenCode config.
 * Complements generate-opencode-agents.sh by ensuring MCPs are always
 * registered even without re-running setup.sh.
 *
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} Number of MCPs registered
 */
function registerMcpServers(config) {
  if (!config.mcp) config.mcp = {};
  if (!config.tools) config.tools = {};

  const registry = getMcpRegistry();
  let registered = 0;

  for (const mcp of registry) {
    if (shouldSkipMcp(mcp, config.tools)) continue;

    if (registerSingleMcp(mcp, config)) registered++;
    applyMcpToolPermissions(mcp, config.tools);
  }

  return registered;
}

// Agent MCP tool permissions extracted to agent-loader.mjs

/**
 * Modify OpenCode config to register aidevops subagents, MCP servers,
 * and per-agent tool permissions.
 *
 * Subagent discovery uses subagent-index.toon (1 file, ~177 lines) instead
 * of scanning 500+ .md files. This ensures @mention works on any repo while
 * keeping startup fast. (t1040)
 *
 * @param {object} config - OpenCode Config object (mutable)
 */
async function configHook(config) {
  if (!config.agent) config.agent = {};

  // --- Lightweight agent registration from pre-built index ---
  const indexAgents = loadAgentIndex(AGENTS_DIR, readIfExists);
  let agentsInjected = 0;

  for (const agent of indexAgents) {
    if (config.agent[agent.name]) continue;

    config.agent[agent.name] = {
      description: agent.description,
      mode: "subagent",
    };
    agentsInjected++;
  }

  // --- MCP registration ---
  const mcpsRegistered = registerMcpServers(config);
  const agentToolsUpdated = applyAgentMcpTools(config);

  // --- OAuth pool: clean up stale provider entries (t1543, t1548) ---
  const poolCleaned = registerPoolProvider(config);

  // Silent unless something was actually changed (avoids TUI flash on startup)
  const parts = [];
  if (agentsInjected > 0) parts.push(`${agentsInjected} agents`);
  if (mcpsRegistered > 0) parts.push(`${mcpsRegistered} MCPs`);
  if (agentToolsUpdated > 0) parts.push(`${agentToolsUpdated} agent tool perms`);
  if (poolCleaned > 0) parts.push(`cleaned ${poolCleaned} stale pool provider${poolCleaned === 1 ? "" : "s"}`);

  if (parts.length > 0) {
    console.error(`[aidevops] Config hook: ${parts.join(", ")}`);
  }
}

// ---------------------------------------------------------------------------
// Phase 3: Quality Hooks (t008.3)
// ---------------------------------------------------------------------------

/**
 * Log a quality event to the quality hooks log file.
 * @param {string} level - "INFO" | "WARN" | "ERROR"
 * @param {string} message
 */
function qualityLog(level, message) {
  try {
    mkdirSync(LOGS_DIR, { recursive: true });
    const timestamp = new Date().toISOString();
    appendFileSync(QUALITY_LOG, `[${timestamp}] [${level}] ${message}\n`);
  } catch {
    // Logging should never break the hook
  }
}

/**
 * Rotate a log file if it exceeds maxBytes.
 * Keeps one .1 backup and truncates the current file.
 * @param {string} logPath - Path to the log file
 * @param {number} maxBytes - Maximum size before rotation
 */
function rotateLogIfNeeded(logPath, maxBytes) {
  try {
    if (!existsSync(logPath)) return;
    const stats = statSync(logPath);
    if (stats.size <= maxBytes) return;
    const backup = `${logPath}.1`;
    // renameSync atomically replaces the destination on POSIX
    renameSync(logPath, backup);
    writeFileSync(logPath, `[${new Date().toISOString()}] [INFO] Log rotated (previous: ${stats.size} bytes)\n`);
  } catch (e) {
    console.error(`[aidevops] Log rotation failed: ${e.message}`);
  }
}

/**
 * Write full quality violation details to the detail log file.
 * Rotates the log if it exceeds QUALITY_DETAIL_MAX_BYTES.
 * @param {string} label - e.g. "Shell quality", "Markdown quality"
 * @param {string} filePath
 * @param {string} report - Full violation report
 */
function qualityDetailLog(label, filePath, report) {
  try {
    mkdirSync(LOGS_DIR, { recursive: true });
    rotateLogIfNeeded(QUALITY_DETAIL_LOG, QUALITY_DETAIL_MAX_BYTES);
    const timestamp = new Date().toISOString();
    appendFileSync(
      QUALITY_DETAIL_LOG,
      `[${timestamp}] ${label} — ${filePath}\n${report}\n\n`,
    );
  } catch (e) {
    console.error(`[aidevops] Quality detail logging failed: ${e.message}`);
  }
}

// Shell validator internals extracted to validators.mjs

/**
 * Scan file content for potential secrets.
 * Lightweight check — not a replacement for secretlint, but catches common patterns.
 * @param {string} filePath
 * @param {string} [content] - Optional content to scan (for Write operations)
 * @returns {{ violations: number, details: string[] }}
 */
function scanForSecrets(filePath, content) {
  const details = [];
  let violations = 0;

  const secretPatterns = [
    { pattern: /(?:api[_-]?key|apikey)\s*[:=]\s*['"][A-Za-z0-9+/=]{20,}['"]/i, label: "API key" },
    { pattern: /(?:secret|password|passwd|pwd)\s*[:=]\s*['"][^'"]{8,}['"]/i, label: "Secret/password" },
    { pattern: /(?:AKIA|ASIA)[A-Z0-9]{16}/, label: "AWS access key" },
    { pattern: /ghp_[A-Za-z0-9]{36}/, label: "GitHub personal access token" },
    { pattern: /gho_[A-Za-z0-9]{36}/, label: "GitHub OAuth token" },
    { pattern: /sk-[A-Za-z0-9]{20,}/, label: "OpenAI/Stripe secret key" },
    { pattern: /-----BEGIN (?:RSA |EC |DSA )?PRIVATE KEY-----/, label: "Private key" },
  ];

  try {
    const text = content || readFileSync(filePath, "utf-8");
    const lines = text.split("\n");

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      // Skip comments and example/placeholder lines
      if (line.trim().startsWith("#") || /example|placeholder|YOUR_/i.test(line)) {
        continue;
      }
      for (const { pattern, label } of secretPatterns) {
        if (pattern.test(line)) {
          details.push(`  Line ${i + 1}: potential ${label} detected`);
          violations++;
          break;
        }
      }
    }
  } catch {
    // File read error — skip
  }

  return { violations, details };
}

/**
 * Run the full pre-commit quality pipeline on a shell script.
 * Mirrors the checks in pre-commit-hook.sh but runs inline.
 * @param {string} filePath
 * @returns {{ totalViolations: number, report: string }}
 */
function runShellQualityPipeline(filePath) {
  const sections = [];
  let totalViolations = 0;

  // 1. ShellCheck
  const shellcheckResult = run(
    `shellcheck -x -S warning "${filePath}" 2>&1`,
    10000,
  );
  if (shellcheckResult) {
    const count = (shellcheckResult.match(/^In /gm) || []).length || 1;
    totalViolations += count;
    sections.push(`ShellCheck (${count} issue${count !== 1 ? "s" : ""}):\n${shellcheckResult}`);
  }

  // 2. Return statements
  const returnResult = validateReturnStatements(filePath);
  if (returnResult.violations > 0) {
    totalViolations += returnResult.violations;
    sections.push(
      `Return statements (${returnResult.violations} missing):\n${returnResult.details.join("\n")}`,
    );
  }

  // 3. Positional parameters
  const paramResult = validatePositionalParams(filePath);
  if (paramResult.violations > 0) {
    totalViolations += paramResult.violations;
    sections.push(
      `Positional params (${paramResult.violations} direct usage):\n${paramResult.details.join("\n")}`,
    );
  }

  // 4. Secrets scan
  const secretResult = scanForSecrets(filePath);
  if (secretResult.violations > 0) {
    totalViolations += secretResult.violations;
    sections.push(
      `Secrets scan (${secretResult.violations} potential):\n${secretResult.details.join("\n")}`,
    );
  }

  const report = sections.length > 0
    ? sections.join("\n\n")
    : "All quality checks passed.";

  return { totalViolations, report };
}

// Markdown quality checks extracted to quality-pipeline.mjs

/**
 * Check if a tool name is a Write or Edit operation.
 * @param {string} tool
 * @returns {boolean}
 */
function isWriteOrEditTool(tool) {
  return tool === "Write" || tool === "Edit" || tool === "write" || tool === "edit";
}

/**
 * Log a quality gate result (violations or pass).
 * @param {string} label - e.g. "Shell quality", "Markdown quality"
 * @param {string} filePath
 * @param {number} totalViolations
 * @param {string} report
 * @param {string} [errorLevel="WARN"]
 */
function logQualityGateResult(label, filePath, totalViolations, report, errorLevel = "WARN") {
  if (totalViolations > 0) {
    const plural = totalViolations !== 1 ? "s" : "";
    qualityLog(errorLevel, `${label}: ${totalViolations} violations in ${filePath}`);
    // Write full details to the detail log (rotated to prevent disk bloat)
    qualityDetailLog(label, filePath, report);
    // Only show console output for security issues (secrets) — quality warnings
    // go to the log file only. The pre-commit hook catches them at commit time.
    if (errorLevel === "ERROR") {
      const reportLines = report.split("\n");
      let consoleReport;
      if (reportLines.length > CONSOLE_MAX_DETAIL_LINES) {
        const shown = reportLines.slice(0, CONSOLE_MAX_DETAIL_LINES).join("\n");
        const omitted = reportLines.length - CONSOLE_MAX_DETAIL_LINES;
        consoleReport = `${shown}\n  ... and ${omitted} more (see ${QUALITY_DETAIL_LOG})`;
      } else {
        consoleReport = report;
      }
      console.error(`[aidevops] ${label}: ${totalViolations} issue${plural} in ${filePath}:\n${consoleReport}`);
    }
  } else {
    qualityLog("INFO", `${label}: PASS for ${filePath}`);
  }
}

/**
 * Pre-tool-use hook: Intent extraction + quality gate for Write/Edit operations.
 *
 * Intent tracing (t1309):
 *   Extracts the `agent__intent` field from tool args (injected by the LLM
 *   per system prompt instruction) and stores it keyed by callID for
 *   retrieval in toolExecuteAfter when the call is recorded to the DB.
 *
 * Quality gate:
 *   Runs the full quality pipeline matching pre-commit-hook.sh checks:
 *   - Shell scripts (.sh): ShellCheck, return statements, positional params, secrets
 *   - Markdown (.md): MD031 (blank lines around code blocks), trailing whitespace
 *   - All files: secrets scanning
 *
 * @param {object} input - { tool, sessionID, callID }
 * @param {object} output - { args } (mutable)
 */
async function toolExecuteBefore(input, output) {
  // Intent tracing (t1309): extract agent__intent from args before execution
  const callID = input.callID || "";
  if (callID && output.args) {
    const intent = extractAndStoreIntent(callID, output.args);
    if (intent) {
      qualityLog("INFO", `Intent [${input.tool}] callID=${callID}: ${intent}`);
    }
  }

  if (!isWriteOrEditTool(input.tool)) return;

  const filePath = output.args?.filePath || output.args?.file_path || "";
  if (!filePath) return;

  if (filePath.endsWith(".sh")) {
    const result = runShellQualityPipeline(filePath);
    logQualityGateResult("Quality gate", filePath, result.totalViolations, result.report);
    const secretResult = scanForSecrets(filePath);
    if (secretResult.violations > 0) {
      logQualityGateResult(
        "SECURITY",
        filePath,
        secretResult.violations,
        secretResult.details.join("\n"),
        "ERROR",
      );
    }
    return;
  }

  if (filePath.endsWith(".md")) {
    const result = runMarkdownQualityPipeline(filePath);
    logQualityGateResult("Markdown quality", filePath, result.totalViolations, result.report);
    return;
  }

  const writeContent = output.args?.content || output.args?.newString || "";
  if (writeContent) {
    const secretResult = scanForSecrets(filePath, writeContent);
    logQualityGateResult("SECURITY", filePath, secretResult.violations,
      secretResult.details.join("\n"), "ERROR");
  }
}

/**
 * Check if a tool name is a Bash operation.
 * @param {string} tool
 * @returns {boolean}
 */
function isBashTool(tool) {
  return tool === "Bash" || tool === "bash";
}

/**
 * Record a git operation pattern via pattern-tracker-helper.sh.
 * @param {string} title - Operation title
 * @param {string} outputText - Command output
 */
function recordGitPattern(title, outputText) {
  const patternTracker = join(SCRIPTS_DIR, "pattern-tracker-helper.sh");
  if (!existsSync(patternTracker)) return;

  const success = !outputText.includes("error") && !outputText.includes("fatal");
  const patternType = success ? "SUCCESS_PATTERN" : "FAILURE_PATTERN";
  run(
    `bash "${patternTracker}" record "${patternType}" "git operation: ${title.substring(0, 100)}" --tag "quality-hook" 2>/dev/null`,
    5000,
  );
}

/**
 * Track Bash tool operations (git, lint) for pattern recording.
 * @param {string} title - Operation title
 * @param {string} outputText - Command output
 */
function trackBashOperation(title, outputText) {
  if (title.includes("git commit") || title.includes("git push")) {
    console.error(`[aidevops] Git operation detected: ${title}`);
    qualityLog("INFO", `Git operation: ${title}`);
    recordGitPattern(title, outputText);
  }

  if (title.includes("shellcheck") || title.includes("linters-local")) {
    const passed = !outputText.includes("error") && !outputText.includes("violation");
    qualityLog(passed ? "INFO" : "WARN", `Lint run: ${title} — ${passed ? "PASS" : "issues found"}`);
  }
}

/**
 * Post-tool-use hook: Quality metrics tracking, pattern recording, and intent logging.
 * Logs tool execution for debugging and feeds data to pattern-tracker-helper.sh.
 * Retrieves the intent captured in toolExecuteBefore and records it to the DB.
 * @param {object} input - { tool, sessionID, callID }
 * @param {object} output - { title, output, metadata } (mutable)
 */
async function toolExecuteAfter(input, output) {
  const toolName = input.tool || "";

  if (isBashTool(toolName)) {
    trackBashOperation(output.title || "", output.output || "");
  }

  if (isWriteOrEditTool(toolName)) {
    const filePath = output.metadata?.filePath || "";
    if (filePath) {
      qualityLog("INFO", `File modified: ${filePath} via ${toolName}`);
    }
  }

  // Intent tracing (t1309): retrieve intent stored by toolExecuteBefore
  const intent = consumeIntent(input.callID || "");

  // Phase 5: LLM observability — record tool calls with intent (t1308, t1309)
  recordToolCall(input, output, intent);
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

// Tool definitions extracted to tools.mjs — imported at top of file

// ---------------------------------------------------------------------------
// Phase 4.5: Intent Tracing (t1309)
// ---------------------------------------------------------------------------
// Inspired by oh-my-pi's agent__intent pattern. The LLM is instructed via
// system prompt to include an `agent__intent` field in every tool call,
// describing its intent in present participle form. The field is extracted
// from tool args in the `tool.execute.before` hook and stored in the
// observability DB alongside the tool call record.
//
// Why system prompt injection instead of JSON Schema injection:
//   OpenCode's plugin API does not expose a hook to modify tool schemas
//   before they are sent to the LLM. The `experimental.chat.system.transform`
//   hook is the closest equivalent — it injects the requirement as a rule
//   the LLM must follow, achieving the same chain-of-thought effect.

/**
 * Field name for intent tracing — matches oh-my-pi convention.
 * @type {string}
 */
const INTENT_FIELD = "agent__intent";

/**
 * Per-callID intent store. Bridges tool.execute.before → tool.execute.after.
 * Maps callID → intent string.
 * @type {Map<string, string>}
 */
const intentByCallId = new Map();

/**
 * Extract and store the intent field from tool call args.
 * Called from toolExecuteBefore — stores intent keyed by callID for
 * retrieval in toolExecuteAfter when the tool call is recorded to the DB.
 *
 * @param {string} callID - Unique tool call identifier
 * @param {object} args - Tool call arguments (may contain agent__intent)
 * @returns {string | undefined} Extracted intent string, or undefined
 */
function extractAndStoreIntent(callID, args) {
  if (!args || typeof args !== "object") return undefined;

  const raw = args[INTENT_FIELD];
  if (typeof raw !== "string") return undefined;

  const intent = raw.trim();
  if (!intent) return undefined;

  intentByCallId.set(callID, intent);

  // Prune old entries to prevent unbounded memory growth
  if (intentByCallId.size > 5000) {
    const keys = Array.from(intentByCallId.keys());
    for (const k of keys.slice(0, 2500)) {
      intentByCallId.delete(k);
    }
  }

  return intent;
}

/**
 * Retrieve and remove the stored intent for a callID.
 * Called from toolExecuteAfter — consumes the intent stored by extractAndStoreIntent.
 *
 * @param {string} callID
 * @returns {string | undefined}
 */
function consumeIntent(callID) {
  const intent = intentByCallId.get(callID);
  if (intent !== undefined) {
    intentByCallId.delete(callID);
  }
  return intent;
}

// ---------------------------------------------------------------------------
// Phase 5: Soft TTSR — Rule Enforcement via Plugin Hooks (t1304)
// ---------------------------------------------------------------------------
// "Soft TTSR" (Text-to-Speech Rules) provides preventative enforcement of
// coding standards without stream-level interception (which OpenCode doesn't
// expose). Three hooks work together:
//
//   1. system.transform  — inject active rules into system prompt (preventative)
//   2. messages.transform — scan prior assistant outputs for violations, inject
//                           correction context into message history (corrective)
//   3. text.complete      — detect violations post-hoc and flag them (observational)
//
// Rules are data-driven: each rule is an object with id, description, a regex
// pattern to detect violations, and a correction message. Rules can be loaded
// from a config file or use the built-in defaults.

const {
  systemTransformHook,
  messagesTransformHook,
  textCompleteHook,
} = createTtsrHooks({
  agentsDir: AGENTS_DIR,
  scriptsDir: SCRIPTS_DIR,
  readIfExists,
  qualityLog,
  run,
  intentField: INTENT_FIELD,
});

// ---------------------------------------------------------------------------
// Main Plugin Export
// ---------------------------------------------------------------------------

/**
 * aidevops OpenCode Plugin
 *
 * Provides:
 * 1. Config hook — lightweight agent index + MCP server registration (t1040)
 * 2. Custom tools — aidevops CLI, memory, pre-edit check, quality check, hook installer
 * 3. Quality hooks — full pre-commit pipeline (ShellCheck, return statements,
 *    positional params, secrets scan, markdown lint) on Write/Edit operations
 * 4. Shell environment — aidevops paths and variables
 * 5. Soft TTSR — preventative rule enforcement via system prompt injection,
 *    corrective feedback via message history scanning, and post-hoc violation
 *    detection via text completion hooks (t1304)
 * 6. LLM observability — event-driven data collection to SQLite (t1308)
 *    Captures assistant message metadata (model, tokens, cost, duration, errors)
 *    via the `event` hook, and tool call counts via `tool.execute.after`.
 *    Writes incrementally to ~/.aidevops/.agent-workspace/observability/llm-requests.db
 * 7. Intent tracing — logs LLM-provided intent alongside tool calls (t1309)
 *    Inspired by oh-my-pi's agent__intent pattern. The LLM is instructed via
 *    system prompt to include an `agent__intent` field in every tool call,
 *    describing its intent in present participle form. Extracted in
 *    `tool.execute.before`, stored in the `tool_calls` table `intent` column.
 * 8. Compaction context — preserves operational state across context resets
 * 9. OpenAI Pro pool — multi-account rotation for ChatGPT Plus/Pro accounts (t1548)
 *    Same token injection architecture as Anthropic pool. Adds "openai-pool" provider
 *    for account management and injects tokens into the built-in "openai" provider.
 * 10. Cursor Pro pool — multi-account rotation for Cursor Pro accounts (t1549)
 *    Extracts credentials from cursor-agent CLI or Cursor IDE's local state DB.
 *    Manages a proxy sidecar (HTTP server) that translates OpenAI-compatible
 *    requests to cursor-agent CLI calls. Adds "cursor-pool" provider for account
 *    management with LRU rotation and 429 failover.
 *
 * MCP registration (Phase 2, t008.2):
 * - Registers all known MCP servers from a data-driven registry
 * - Enforces eager/lazy loading policy (all MCPs lazy-load on demand)
 * - Sets global tool permissions and per-agent MCP tool enablement
 * - Skips MCPs whose required binaries aren't installed
 * - Complements generate-opencode-agents.sh (shell script takes precedence)
 *
 * @type {import('@opencode-ai/plugin').Plugin}
 */
export async function AidevopsPlugin({ directory, client }) {
  // Phase 6: Initialise LLM observability (t1308)
  initObservability();

  // Phase 7: OAuth pool — seed auth entries so providers appear in connect dialog (t1543, t1548, t1549)
  await initPoolAuth(client);

  // Phase 7b: OAuth pool tools (t1543, t1548, t1549)
  const baseTools = createTools(SCRIPTS_DIR, run, {
    runShellQualityPipeline,
    runMarkdownQualityPipeline,
    scanForSecrets,
  });
  baseTools["model-accounts-pool"] = createPoolTool(client);

  return {
    // Phase 1+2: Lightweight agent index + MCP registration
    config: async (config) => configHook(config),

    // Phase 1+7: Custom tools (extracted to tools.mjs) + pool management (t1543)
    tool: baseTools,

    // Phase 3: Quality hooks
    "tool.execute.before": toolExecuteBefore,
    "tool.execute.after": toolExecuteAfter,

    // Phase 4: Shell environment
    "shell.env": shellEnvHook,

    // Phase 5: Soft TTSR — rule enforcement (t1304)
    "experimental.chat.system.transform": systemTransformHook,
    "experimental.chat.messages.transform": messagesTransformHook,
    "experimental.text.complete": textCompleteHook,

    // Phase 6: LLM observability — capture assistant message metadata (t1308)
    event: async (input) => handleEvent(input),

    // Phase 7: OAuth multi-account pool (t1543, t1548, t1549)
    // OpenCode v1.2.27 only supports auth as a single object, not an array.
    // Using the Anthropic pool hook as the primary — it's the most-used provider.
    // OpenAI and Cursor accounts are added via oauth-pool-helper.sh instead.
    auth: createPoolAuthHook(client),

    // Compaction context (includes OMOC state when detected)
    "experimental.session.compacting": async (input, output) =>
      compactingHook(input, output, directory),
  };
}
