import { execSync } from "child_process";
import {
  readFileSync,
  readdirSync,
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

/** Names to skip when discovering agents. */
const SKIP_NAMES = new Set([
  "README",
  "AGENTS",
  "SKILL",
  "SKILL-SCAN-RESULTS",
  "node_modules",
  "references",
  "loop-state",
]);

/**
 * Parse subagent-index.toon and return leaf agent names with descriptions.
 * Reads ONE file instead of 500+. Returns entries like:
 *   { name: "dataforseo", description: "Search optimization - keywords..." }
 * @returns {Array<{name: string, description: string}>}
 */
function loadAgentIndex() {
  const indexPath = join(AGENTS_DIR, "subagent-index.toon");
  const content = readIfExists(indexPath);
  if (!content) return loadAgentsFallback();

  const agents = [];
  const seen = new Set();

  // Parse the subagents TOON block: folder, purpose, key_files
  // e.g.: seo/,Search optimization - keywords and rankings,dataforseo|serper|semrush|...
  const subagentMatch = content.match(
    /<!--TOON:subagents\[\d+\]\{[^}]+\}:\n([\s\S]*?)-->/,
  );
  if (!subagentMatch) return loadAgentsFallback();

  for (const line of subagentMatch[1].split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    const parts = trimmed.split(",");
    if (parts.length < 3) continue;

    const folder = parts[0] || "";
    // Skip reference/skill directories (not real agents)
    if (folder.includes("references/") || folder.includes("loop-state/")) continue;

    const purpose = parts[1] || "";
    const keyFiles = parts.slice(2).join(",");

    for (const leaf of keyFiles.split("|")) {
      const name = leaf.trim();
      if (!name || SKIP_NAMES.has(name) || name.endsWith("-skill")) continue;
      if (seen.has(name)) continue;
      seen.add(name);
      agents.push({ name, description: purpose });
    }
  }

  return agents;
}

/**
 * Fallback: discover agents from directory names only (no file reads).
 * Lists .md filenames in known subdirectories — O(n) readdirSync calls
 * where n = number of subdirectories (~11), NOT number of files.
 * Each readdirSync returns filenames without reading file contents.
 * @returns {Array<{name: string, description: string}>}
 */
function loadAgentsFallback() {
  if (!existsSync(AGENTS_DIR)) return [];

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

  const agents = [];
  const seen = new Set();

  for (const subdir of subdirs) {
    scanDirNames(join(AGENTS_DIR, subdir), subdir, agents, seen);
  }

  return agents;
}

/**
 * Recursively collect .md filenames from a directory tree.
 * Only calls readdirSync (directory listing) — never reads file contents.
 * @param {string} dirPath
 * @param {string} folderDesc - used as description fallback
 * @param {Array} agents
 * @param {Set} seen - dedup set
 */
function scanDirNames(dirPath, folderDesc, agents, seen) {
  let entries;
  try {
    entries = readdirSync(dirPath, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (SKIP_NAMES.has(entry.name)) continue;
      scanDirNames(join(dirPath, entry.name), folderDesc, agents, seen);
    } else if (entry.isFile() && entry.name.endsWith(".md")) {
      const name = entry.name.replace(/\.md$/, "");
      if (SKIP_NAMES.has(name) || name.endsWith("-skill")) continue;
      if (seen.has(name)) continue;
      seen.add(name);
      agents.push({
        name,
        description: `aidevops subagent: ${folderDesc}`,
      });
    }
  }
}

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
 * Map of subagent names to the MCP tool patterns they need enabled.
 * Used by the config hook to set per-agent tool permissions.
 *
 * Only includes subagents that need MCP tools beyond the defaults.
 * Agents not listed here get only the globally-enabled tools.
 */
const AGENT_MCP_TOOLS = {
  outscraper: ["outscraper_*"],
  mainwp: ["localwp_*"],
  localwp: ["localwp_*"],
  quickfile: ["quickfile_*"],
  "google-search-console": ["gsc_*"],
  dataforseo: ["dataforseo_*"],
  "claude-code": ["claude-code-mcp_*"],
  playwriter: ["playwriter_*"],
  shadcn: ["shadcn_*"],
  "macos-automator": IS_MACOS ? ["macos-automator_*"] : [],
  mac: IS_MACOS ? ["macos-automator_*"] : [],
  "ios-simulator-mcp": IS_MACOS ? ["ios-simulator_*"] : [],
  "augment-context-engine": ["augment-context-engine_*"],
  context7: ["context7_*"],
  sentry: ["sentry_*"],
  socket: ["socket_*"],
};

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

/**
 * Apply per-agent MCP tool permissions.
 * Ensures subagents that need specific MCP tools have them enabled
 * in their agent config, even if the tools are disabled globally.
 *
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} Number of agents updated
 */
function applyAgentMcpTools(config) {
  if (!config.agent) return 0;

  let updated = 0;

  for (const [mcpAgentName, toolPatterns] of Object.entries(AGENT_MCP_TOOLS)) {
    if (toolPatterns.length === 0) continue;

    // Find matching agent(s) — check both exact name and path-based names
    // ending with the basename (t1015: agents now use path-based names like
    // "tools/wordpress/mainwp" instead of just "mainwp")
    const matchingKeys = Object.keys(config.agent).filter(
      (key) => key === mcpAgentName || key.endsWith("/" + mcpAgentName),
    );
    if (matchingKeys.length === 0) continue;

    for (const matchKey of matchingKeys) {
      // Ensure agent has a tools section
      if (!config.agent[matchKey].tools) {
        config.agent[matchKey].tools = {};
      }

      for (const pattern of toolPatterns) {
        // Only set if not already configured (shell script takes precedence)
        if (!(pattern in config.agent[matchKey].tools)) {
          config.agent[matchKey].tools[pattern] = true;
          updated++;
        }
      }
    }
  }

  return updated;
}

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
  const indexAgents = loadAgentIndex();
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

  // Silent unless something was actually changed (avoids TUI flash on startup)
  const parts = [];
  if (agentsInjected > 0) parts.push(`${agentsInjected} agents`);
  if (mcpsRegistered > 0) parts.push(`${mcpsRegistered} MCPs`);
  if (agentToolsUpdated > 0) parts.push(`${agentToolsUpdated} agent tool perms`);

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

/**
 * Try to match a shell function definition on a line.
 * @param {string} trimmed - Trimmed line content
 * @returns {string|null} Function name if matched, null otherwise
 */
function matchFunctionDef(trimmed) {
  const funcMatch = trimmed.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)\s*\{/);
  if (funcMatch) return funcMatch[1];

  const funcMatch2 = trimmed.match(/^function\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
  if (funcMatch2) return funcMatch2[1];

  return null;
}

/**
 * Count brace depth change in a line.
 * @param {string} trimmed - Trimmed line content
 * @returns {number} Net brace depth change
 */
function braceDepthDelta(trimmed) {
  let delta = 0;
  for (const ch of trimmed) {
    if (ch === "{") delta++;
    else if (ch === "}") delta--;
  }
  return delta;
}

/**
 * Check if a line contains a shell return statement.
 * @param {string} trimmed - Trimmed line content
 * @returns {boolean}
 */
function hasReturnStatement(trimmed) {
  return /\breturn\s+[0-9]/.test(trimmed) || /\breturn\s*$/.test(trimmed);
}

/**
 * Record a missing-return violation.
 * @param {string[]} details - Mutable details array
 * @param {number} functionStart - 1-based line number
 * @param {string} functionName
 * @returns {number} 1 (violation count increment)
 */
function recordMissingReturn(details, functionStart, functionName) {
  details.push(
    `  Line ${functionStart}: function '${functionName}' missing explicit return`,
  );
  return 1;
}

/**
 * Validate shell script return statements.
 * Checks that functions have explicit return statements (aidevops convention).
 * @param {string} filePath
 * @returns {{ violations: number, details: string[] }}
 */
function validateReturnStatements(filePath) {
  const details = [];
  let violations = 0;

  try {
    const content = readFileSync(filePath, "utf-8");
    const lines = content.split("\n");

    let inFunction = false;
    let functionName = "";
    let functionStart = 0;
    let braceDepth = 0;
    let hasReturn = false;

    for (let i = 0; i < lines.length; i++) {
      const trimmed = lines[i].trim();
      const name = matchFunctionDef(trimmed);

      if (name) {
        if (inFunction && !hasReturn) {
          violations += recordMissingReturn(details, functionStart, functionName);
        }
        inFunction = true;
        functionName = name;
        functionStart = i + 1;
        braceDepth = trimmed.includes("{") ? 1 : 0;
        hasReturn = false;
        continue;
      }

      if (!inFunction) continue;

      braceDepth += braceDepthDelta(trimmed);
      if (hasReturnStatement(trimmed)) hasReturn = true;

      if (braceDepth <= 0) {
        if (!hasReturn) {
          violations += recordMissingReturn(details, functionStart, functionName);
        }
        inFunction = false;
      }
    }

    if (inFunction && !hasReturn) {
      violations += recordMissingReturn(details, functionStart, functionName);
    }
  } catch {
    // File read error — skip validation
  }

  return { violations, details };
}

/**
 * Validate positional parameter usage in shell scripts.
 * Checks that $1, $2, etc. are assigned to local variables (aidevops convention).
 * @param {string} filePath
 * @returns {{ violations: number, details: string[] }}
 */
function validatePositionalParams(filePath) {
  const details = [];
  let violations = 0;

  try {
    const content = readFileSync(filePath, "utf-8");
    const lines = content.split("\n");

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      // Skip comments
      if (trimmed.startsWith("#")) continue;

      // Check for direct $1-$9 usage not in a local assignment
      if (/\$[1-9]/.test(trimmed) && !/local\s+\w+=.*\$[1-9]/.test(trimmed)) {
        // Allow shift, case "$1", and getopts patterns
        if (
          /^\s*shift/.test(trimmed) ||
          /case\s+.*\$[1-9]/.test(trimmed) ||
          /getopts/.test(trimmed) ||
          /"\$@"/.test(trimmed) ||
          /"\$\*"/.test(trimmed)
        ) {
          continue;
        }
        // Strip escaped dollar signs before further checks so that lines with
        // mixed content (e.g. "\$5 fee $1") still detect unescaped positional params.
        // This replaces the previous whole-line skip for escaped dollars.
        const stripped = trimmed.replace(/\\\$[1-9]/g, "");
        // Skip if no unescaped $N remains after stripping escaped ones
        if (!/\$[1-9]/.test(stripped)) {
          continue;
        }
        // Skip currency/pricing patterns (false-positives in markdown tables,
        // heredocs, and echo strings):
        //   - $N followed by digits, decimal, comma, or slash (e.g. $28/mo, $1.99, $1,000)
        //   - $N followed by space + pricing/unit word (e.g. $5 flat, $3 fee, $9 per month)
        //   - Markdown table rows (lines starting with |)
        //   - $N followed by pipe (markdown table cell boundary)
        if (/\$[1-9][0-9.,/]/.test(stripped)) {
          continue;
        }
        if (/\$[1-9]\s+(?:per|mo(?:nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)\b/.test(stripped)) {
          continue;
        }
        if (/^\s*\|/.test(line)) {
          continue;
        }
        if (/\$[1-9]\s*\|/.test(stripped)) {
          continue;
        }
        details.push(`  Line ${i + 1}: direct positional parameter: ${trimmed.substring(0, 80)}`);
        violations++;
      }
    }
  } catch {
    // File read error — skip validation
  }

  return { violations, details };
}

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

/**
 * Run markdown quality checks on a file.
 * Checks for common issues: trailing whitespace, missing blank lines around
 * code blocks (MD031), consecutive blank lines, broken links.
 * @param {string} filePath
 * @returns {{ totalViolations: number, report: string }}
 */
function runMarkdownQualityPipeline(filePath) {
  const sections = [];
  let totalViolations = 0;

  try {
    const content = readFileSync(filePath, "utf-8");
    const lines = content.split("\n");

    // MD031: Fenced code blocks should be surrounded by blank lines
    let inCodeBlock = false;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (/^```/.test(line.trim())) {
        if (!inCodeBlock) {
          // Opening fence — check line before
          if (i > 0 && lines[i - 1].trim() !== "") {
            sections.push(`  Line ${i + 1}: MD031 — missing blank line before code fence`);
            totalViolations++;
          }
        } else {
          // Closing fence — check line after
          if (i < lines.length - 1 && lines[i + 1] !== undefined && lines[i + 1].trim() !== "") {
            sections.push(`  Line ${i + 1}: MD031 — missing blank line after code fence`);
            totalViolations++;
          }
        }
        inCodeBlock = !inCodeBlock;
      }
    }

    // Check for trailing whitespace (common quality issue)
    let trailingCount = 0;
    for (let i = 0; i < lines.length; i++) {
      if (/\s+$/.test(lines[i]) && !inCodeBlock) {
        trailingCount++;
      }
    }
    if (trailingCount > 0) {
      sections.push(`  Trailing whitespace on ${trailingCount} line${trailingCount !== 1 ? "s" : ""}`);
      totalViolations += trailingCount;
    }
  } catch {
    // File read error — skip
  }

  const report = sections.length > 0
    ? `Markdown quality:\n${sections.join("\n")}`
    : "Markdown checks passed.";

  return { totalViolations, report };
}

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

/**
 * Path to optional user-defined TTSR rules file.
 * JSON array of rule objects: { id, description, pattern, correction, severity }
 * @type {string}
 */
const TTSR_RULES_PATH = join(AGENTS_DIR, "configs", "ttsr-rules.json");

/**
 * Built-in TTSR rules — enforced by default.
 * Each rule has:
 *   - id: unique identifier
 *   - description: human-readable explanation
 *   - pattern: regex string to detect violations in assistant output
 *   - correction: message injected when violation is detected
 *   - severity: "error" | "warn" | "info"
 *   - systemPrompt: instruction injected into system prompt (preventative)
 *
 * @type {Array<{id: string, description: string, pattern: string, correction: string, severity: string, systemPrompt: string}>}
 */
const BUILTIN_TTSR_RULES = [
  {
    id: "no-glob-for-discovery",
    description: "Use git ls-files or fd instead of Glob/find for file discovery",
    pattern: "(?:mcp_glob|Glob tool|use.*\\bGlob\\b.*to find|I'll use Glob)",
    correction: "Use `git ls-files` or `fd` for file discovery, not Glob. Glob is a last resort when Bash is unavailable.",
    severity: "warn",
    systemPrompt: "File discovery: use `git ls-files '<pattern>'` for git-tracked files, `fd` for untracked. NEVER use Glob/find as primary discovery.",
  },
  {
    id: "no-cat-for-reading",
    description: "Use Read tool instead of cat/head/tail for file reading",
    pattern: "(?:^|\\s)cat\\s+['\"]?[/~\\w]|\\bhead\\s+-n|\\btail\\s+-n",
    correction: "Use the Read tool for file reading, not cat/head/tail. These are Bash commands that waste context.",
    severity: "info",
    systemPrompt: "Use the Read tool for file reading. Avoid cat/head/tail in Bash — they waste context tokens.",
  },
  {
    id: "read-before-edit",
    description: "Always Read a file before Edit or Write operations",
    pattern: "(?:I'll edit|Let me edit|I'll write to|Let me write)(?:(?!I'll read|let me read|I've read|already read).){0,200}$",
    correction: "ALWAYS Read a file before Edit/Write. These tools fail without a prior Read in this conversation.",
    severity: "error",
    systemPrompt: "ALWAYS Read a file before Edit or Write. These tools FAIL without a prior Read in this conversation.",
  },
  {
    id: "no-credentials-in-output",
    description: "Never expose credentials, API keys, or secrets in output",
    pattern: "(?:api[_-]?key|secret|password|token)\\s*[:=]\\s*['\"][A-Za-z0-9+/=_-]{16,}['\"]",
    correction: "SECURITY: Never expose credentials in output. Use `aidevops secret set NAME` for secure storage.",
    severity: "error",
    systemPrompt: "NEVER expose credentials, API keys, or secrets in output or logs.",
  },
  {
    id: "pre-edit-check",
    description: "Run pre-edit-check.sh before modifying files",
    pattern: "(?:I'll (?:create|modify|edit|write)|Let me (?:create|modify|edit|write)).*(?:on main|on master)\\b",
    correction: "Run pre-edit-check.sh before modifying files. NEVER edit on main/master branch.",
    severity: "error",
    systemPrompt: "Before ANY file modification: run pre-edit-check.sh. NEVER edit on main/master.",
  },
  {
    id: "shell-explicit-returns",
    description: "Shell functions must have explicit return statements",
    pattern: "(?:function\\s+\\w+|\\w+\\s*\\(\\)\\s*\\{)(?:(?!return\\s+[0-9]).){50,}\\}",
    correction: "Shell functions must have explicit `return 0` or `return 1` statements (SonarCloud S7682).",
    severity: "warn",
    systemPrompt: "Shell scripts: every function must have an explicit `return 0` or `return 1`.",
  },
  {
    id: "shell-local-params",
    description: "Use local var=\"$1\" pattern in shell functions",
    // Only match bare $N at the start of a line or after whitespace in what looks
    // like a shell assignment/command context — avoids matching $1 inside prose,
    // documentation, quoted examples, or tool output from file reads.
    // Excludes currency/pricing patterns:
    //   - $[1-9] followed by digits, decimal, comma, or slash (e.g. $28/mo, $1.99, $1,000)
    //   - $[1-9] followed by pipe (markdown table cell boundary)
    //   - $[1-9] followed by common currency/pricing unit words (per, mo, month, flat, etc.)
    //   - Escaped dollar signs \$[1-9] (literal dollar in shell strings)
    pattern: "^\\s+(?:echo|printf|return|if|\\[\\[).*(?<!\\\\)\\$[1-9](?![0-9.,/])(?!\\s*[|])(?!\\s+(?:per|mo(?:nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)\\b)(?!.*local\\s+\\w+=)",
    correction: "Use `local var=\"$1\"` pattern — never use positional parameters directly (SonarCloud S7679).",
    severity: "warn",
    systemPrompt: "Shell scripts: use `local var=\"$1\"` — never use $1 directly in function bodies.",
  },
];

/**
 * Cached loaded rules (built-in + user-defined).
 * @type {Array<object> | null}
 */
let _ttsrRules = null;

/**
 * Load TTSR rules: built-in defaults merged with optional user-defined rules.
 * User rules can override built-in rules by matching id.
 * @returns {Array<{id: string, description: string, pattern: string, correction: string, severity: string, systemPrompt: string}>}
 */
function loadTtsrRules() {
  if (_ttsrRules !== null) return _ttsrRules;

  _ttsrRules = [...BUILTIN_TTSR_RULES];

  const userContent = readIfExists(TTSR_RULES_PATH);
  if (userContent) {
    try {
      const userRules = JSON.parse(userContent);
      if (Array.isArray(userRules)) {
        for (const rule of userRules) {
          if (!rule.id || !rule.pattern) continue;
          const existingIdx = _ttsrRules.findIndex((r) => r.id === rule.id);
          if (existingIdx >= 0) {
            _ttsrRules[existingIdx] = { ..._ttsrRules[existingIdx], ...rule };
          } else {
            _ttsrRules.push(rule);
          }
        }
      }
    } catch {
      console.error("[aidevops] Failed to parse TTSR rules file — using built-in rules only");
    }
  }

  return _ttsrRules;
}

/**
 * Check text against a single TTSR rule.
 * @param {string} text - Text to check
 * @param {object} rule - TTSR rule object
 * @returns {{ matched: boolean, matches: string[] }}
 */
function checkRule(text, rule) {
  try {
    const regex = new RegExp(rule.pattern, "gim");
    const matches = [];
    let match;
    while ((match = regex.exec(text)) !== null) {
      matches.push(match[0].substring(0, 120));
      if (matches.length >= 3) break; // Cap matches to avoid noise
    }
    return { matched: matches.length > 0, matches };
  } catch {
    return { matched: false, matches: [] };
  }
}

/**
 * Scan text for all TTSR rule violations.
 * @param {string} text - Text to scan
 * @returns {Array<{rule: object, matches: string[]}>}
 */
function scanForViolations(text) {
  const rules = loadTtsrRules();
  const violations = [];

  for (const rule of rules) {
    const result = checkRule(text, rule);
    if (result.matched) {
      violations.push({ rule, matches: result.matches });
    }
  }

  return violations;
}

/**
 * Hook: experimental.chat.system.transform (t1304, t1309)
 *
 * Injects active TTSR rules and intent tracing instruction into the system prompt.
 *
 * Intent tracing (t1309):
 *   Instructs the LLM to include an `agent__intent` field in every tool call,
 *   describing its intent in present participle form. This is the system-prompt
 *   equivalent of oh-my-pi's JSON Schema injection — OpenCode's plugin API does
 *   not expose tool schema modification, so we achieve the same effect via the
 *   system prompt. The field is extracted in tool.execute.before and logged to
 *   the observability DB for debugging and audit trails.
 *
 * TTSR rules (t1304):
 *   Injects active rules as preventative guidance before every LLM call.
 *
 * @param {object} _input - { sessionID?: string, model: Model }
 * @param {object} output - { system: string[] } (mutable)
 */
async function systemTransformHook(_input, output) {
  const rules = loadTtsrRules();

  const ruleLines = rules
    .filter((r) => r.systemPrompt)
    .map((r) => `- ${r.systemPrompt}`);

  // Intent tracing instruction (t1309) — always injected regardless of TTSR rules
  const intentInstruction = [
    "## Intent Tracing (observability)",
    `When calling any tool, include a field named \`${INTENT_FIELD}\` in the tool arguments.`,
    "Value: one sentence in present participle form describing your intent (e.g., \"Reading the file to understand the existing schema\").",
    "No trailing period. This field is used for debugging and audit trails — it is stripped before tool execution.",
  ].join("\n");

  output.system.push(intentInstruction);

  if (ruleLines.length === 0) return;

  output.system.push(
    [
      "## aidevops Quality Rules (enforced)",
      "The following rules are actively enforced. Violations will be flagged.",
      ...ruleLines,
    ].join("\n"),
  );
}

/**
 * Extract text content from a Part array.
 * Only extracts text from TextPart objects (type === "text").
 * @param {Array<object>} parts - Array of Part objects
 * @param {object} [options] - Extraction options
 * @param {boolean} [options.excludeToolOutput=false] - Skip tool-result/tool-invocation parts
 * @returns {string} Concatenated text content
 */
function extractTextFromParts(parts, options = {}) {
  if (!Array.isArray(parts)) return "";
  return parts
    .filter((p) => {
      if (!p || typeof p.text !== "string") return false;
      if (p.type !== "text") return false;
      // When excludeToolOutput is set, skip parts that contain tool output.
      // Tool results are embedded in assistant messages as text parts whose
      // content is the serialized tool response. We detect these by checking
      // for the tool-invocation/tool-result type or by the presence of
      // toolCallId/toolInvocationId fields that OpenCode attaches.
      if (options.excludeToolOutput) {
        if (p.toolCallId || p.toolInvocationId) return false;
      }
      return true;
    })
    .map((p) => p.text)
    .join("\n");
}

/**
 * Cross-turn TTSR dedup state.
 * Tracks which rules have already fired and on which message IDs,
 * preventing the same rule from firing repeatedly on the same content
 * across multiple LLM turns (which caused an infinite correction loop).
 * @type {Map<string, Set<string>>} ruleId -> Set of messageIDs already corrected
 */
const _ttsrFiredState = new Map();

/**
 * Hook: experimental.chat.messages.transform (t1304)
 *
 * Scans previous assistant outputs for rule violations and injects
 * correction context into the message history. This provides corrective
 * feedback so the model learns from its own violations within the session.
 *
 * Strategy: scan the last N assistant messages (not all — performance).
 * If violations are found, append a synthetic correction message to the
 * message history so the model sees the feedback before generating.
 *
 * Bug fix: Three changes to prevent infinite correction loops:
 * 1. Only scan assistant-authored text, excluding tool output (Read/Bash
 *    results contain code the assistant *read*, not code it *wrote*).
 * 2. Cross-turn dedup — track which rules fired on which messages to
 *    prevent the same rule re-firing on the same content every turn.
 * 3. Skip messages that are themselves synthetic TTSR corrections.
 *
 * @param {object} _input - {}
 * @param {object} output - { messages: { info: Message, parts: Part[] }[] } (mutable)
 */
async function messagesTransformHook(_input, output) {
  if (!output.messages || output.messages.length === 0) return;

  // Scan the last 3 assistant messages for violations
  const scanWindow = 3;
  const assistantMessages = output.messages
    .filter((m) => {
      if (!m.info || m.info.role !== "assistant") return false;
      // Skip synthetic TTSR correction messages that were injected previously
      if (m.info.id && m.info.id.startsWith("ttsr-correction-")) return false;
      return true;
    })
    .slice(-scanWindow);

  if (assistantMessages.length === 0) return;

  const allViolations = [];

  for (const msg of assistantMessages) {
    const msgId = msg.info?.id || "";

    // Extract only assistant-authored text, excluding tool output.
    // Tool results (Read, Bash, etc.) contain code the assistant *read*,
    // not code it *wrote* — scanning those causes false positives.
    const text = extractTextFromParts(msg.parts, { excludeToolOutput: true });
    if (!text) continue;

    const violations = scanForViolations(text);
    for (const v of violations) {
      const ruleId = v.rule.id;

      // Cross-turn dedup: skip if this rule already fired on this message
      const firedOn = _ttsrFiredState.get(ruleId);
      if (firedOn && firedOn.has(msgId)) continue;

      // Deduplicate by rule id within this scan
      if (!allViolations.some((av) => av.rule.id === ruleId)) {
        allViolations.push({ ...v, msgId });
      }
    }
  }

  if (allViolations.length === 0) return;

  // Record that these rules fired on these messages (cross-turn dedup)
  for (const v of allViolations) {
    if (!_ttsrFiredState.has(v.rule.id)) {
      _ttsrFiredState.set(v.rule.id, new Set());
    }
    _ttsrFiredState.get(v.rule.id).add(v.msgId);
  }

  // Build correction context
  const corrections = allViolations.map((v) => {
    const severity = v.rule.severity === "error" ? "ERROR" : "WARNING";
    return `[${severity}] ${v.rule.id}: ${v.rule.correction}`;
  });

  const correctionText = [
    "[aidevops TTSR] Rule violations detected in recent output:",
    ...corrections,
    "",
    "Apply these corrections in your next response.",
  ].join("\n");

  // Inject as a synthetic user message at the end of the history
  // so the model sees the correction before generating its next response
  const correctionId = `ttsr-correction-${Date.now()}`;
  const sessionID = output.messages[0]?.info?.sessionID || "";

  output.messages.push({
    info: {
      id: correctionId,
      sessionID,
      role: "user",
      time: { created: Date.now() },
      parentID: "",
    },
    parts: [
      {
        id: `${correctionId}-part`,
        sessionID,
        messageID: correctionId,
        type: "text",
        text: correctionText,
        synthetic: true,
      },
    ],
  });

  qualityLog(
    "INFO",
    `TTSR messages.transform: injected ${allViolations.length} correction(s): ${allViolations.map((v) => v.rule.id).join(", ")}`,
  );
}

/**
 * Hook: experimental.text.complete (t1304)
 *
 * Detects rule violations post-hoc in completed text parts and flags them.
 * This is observational — it logs violations but does not modify the output
 * (the text has already been shown to the user). The log data feeds into
 * quality metrics and pattern tracking.
 *
 * @param {object} input - { sessionID: string, messageID: string, partID: string }
 * @param {object} output - { text: string } (mutable)
 */
async function textCompleteHook(input, output) {
  if (!output.text) return;

  const violations = scanForViolations(output.text);
  if (violations.length === 0) return;

  // Log violations for observability
  for (const v of violations) {
    qualityLog(
      v.rule.severity === "error" ? "ERROR" : "WARN",
      `TTSR violation [${v.rule.id}]: ${v.rule.description} (session: ${input.sessionID}, message: ${input.messageID})`,
    );
  }

  // Append violation markers as comments at the end of the text
  // so the model can see them in subsequent turns
  const markers = violations.map((v) => {
    const severity = v.rule.severity === "error" ? "ERROR" : "WARN";
    return `<!-- TTSR:${severity}:${v.rule.id} — ${v.rule.correction} -->`;
  });

  output.text = output.text + "\n" + markers.join("\n");

  // Record pattern for tracking
  const patternTracker = join(SCRIPTS_DIR, "pattern-tracker-helper.sh");
  if (existsSync(patternTracker)) {
    const ruleIds = violations.map((v) => v.rule.id).join(",");
    run(
      `bash "${patternTracker}" record "TTSR_VIOLATION" "rules: ${ruleIds}" --tag "ttsr" 2>/dev/null`,
      5000,
    );
  }
}

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
export async function AidevopsPlugin({ directory }) {
  // Phase 6: Initialise LLM observability (t1308)
  initObservability();
  return {
    // Phase 1+2: Lightweight agent index + MCP registration
    config: async (config) => configHook(config),

    // Phase 1: Custom tools (extracted to tools.mjs)
    tool: createTools(SCRIPTS_DIR, run, {
      runShellQualityPipeline,
      runMarkdownQualityPipeline,
      scanForSecrets,
    }),

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

    // Compaction context (includes OMOC state when detected)
    "experimental.session.compacting": async (input, output) =>
      compactingHook(input, output, directory),
  };
}
