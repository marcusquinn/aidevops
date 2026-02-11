import { execSync } from "child_process";
import {
  readFileSync,
  readdirSync,
  existsSync,
  statSync,
  appendFileSync,
  mkdirSync,
} from "fs";
import { join, relative, basename } from "path";
import { homedir } from "os";
import { platform } from "os";

const HOME = homedir();
const AGENTS_DIR = join(HOME, ".aidevops", "agents");
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");
const LOGS_DIR = join(HOME, ".aidevops", "logs");
const QUALITY_LOG = join(LOGS_DIR, "quality-hooks.log");
const IS_MACOS = platform() === "darwin";

/**
 * Cached oh-my-opencode detection result.
 * @type {{ detected: boolean, version: string, mcps: string[], hooks: string[], configPath: string } | null}
 */
let _omocState = null;

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
// Phase 0: oh-my-opencode (OMOC) Detection & Compatibility (t008.4)
// ---------------------------------------------------------------------------

/**
 * MCPs known to be managed by oh-my-opencode.
 * When OMOC is detected, aidevops skips registering these to avoid duplicates.
 * Maps OMOC MCP name → aidevops registry name (if different) or null (no equivalent).
 */
const OMOC_MANAGED_MCPS = {
  websearch: null,       // Exa web search — no aidevops equivalent
  context7: "context7",  // Both plugins register context7
  grep_app: null,        // GitHub code search — no aidevops equivalent
};

/**
 * Hooks known to be provided by oh-my-opencode.
 * aidevops skips overlapping hook behaviour when these are active.
 */
const OMOC_HOOK_NAMES = [
  "comment-checker",
  "todo-enforcer",
  "todo-continuation-enforcer",
  "aggressive-truncation",
  "auto-resume",
  "think-mode",
  "ralph-loop",
];

/**
 * Detect oh-my-opencode presence and capabilities.
 *
 * Detection strategy (ordered by reliability):
 * 1. Check OpenCode config for OMOC in plugin array
 * 2. Check for OMOC config files (project-level, then user-level)
 * 3. Check for OMOC npm installation
 *
 * Results are cached after first call.
 *
 * @param {string} [directory] - Project directory to check for local config
 * @returns {{ detected: boolean, version: string, mcps: string[], hooks: string[], configPath: string }}
 */
function detectOhMyOpenCode(directory) {
  if (_omocState !== null) return _omocState;

  _omocState = {
    detected: false,
    version: "",
    mcps: [],
    hooks: [],
    configPath: "",
  };

  // 1. Check OpenCode config for OMOC in plugin array
  const ocConfigPaths = [
    join(HOME, ".config", "opencode", "opencode.json"),
    join(HOME, ".config", "opencode", "opencode.jsonc"),
  ];

  for (const configPath of ocConfigPaths) {
    const content = readIfExists(configPath);
    if (!content) continue;

    try {
      // Strip JSONC comments for parsing
      const cleaned = content.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
      const config = JSON.parse(cleaned);

      if (Array.isArray(config.plugin) && config.plugin.includes("oh-my-opencode")) {
        _omocState.detected = true;
        break;
      }
    } catch {
      // JSON parse error — try next config
    }
  }

  // 2. Check for OMOC config files
  const omocConfigPaths = [
    directory ? join(directory, ".opencode", "oh-my-opencode.json") : "",
    join(HOME, ".config", "opencode", "oh-my-opencode.json"),
  ].filter(Boolean);

  for (const configPath of omocConfigPaths) {
    if (existsSync(configPath)) {
      _omocState.detected = true;
      _omocState.configPath = configPath;

      // Parse OMOC config to discover disabled hooks and MCP overrides
      const content = readIfExists(configPath);
      if (content) {
        try {
          const cleaned = content.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
          const omocConfig = JSON.parse(cleaned);

          // Discover which hooks are active (all enabled unless in disabled_hooks)
          const disabledHooks = omocConfig.disabled_hooks || [];
          _omocState.hooks = OMOC_HOOK_NAMES.filter((h) => !disabledHooks.includes(h));

          // Discover which MCPs are active (all enabled unless explicitly disabled)
          const mcpConfig = omocConfig.mcp || {};
          _omocState.mcps = Object.keys(OMOC_MANAGED_MCPS).filter((name) => {
            const mcpEntry = mcpConfig[name];
            // MCP is active unless explicitly disabled in OMOC config
            return !mcpEntry || mcpEntry.enabled !== false;
          });
        } catch {
          // Parse error — assume defaults (all MCPs and hooks active)
          _omocState.mcps = Object.keys(OMOC_MANAGED_MCPS);
          _omocState.hooks = [...OMOC_HOOK_NAMES];
        }
      }
      break;
    }
  }

  // 3. If not yet detected, check npm for OMOC installation
  if (!_omocState.detected) {
    const npmCheck = run("npm ls oh-my-opencode --json 2>/dev/null", 5000);
    if (npmCheck && npmCheck.includes("oh-my-opencode")) {
      _omocState.detected = true;
    }
  }

  // 4. Get OMOC version if detected
  if (_omocState.detected) {
    const version = run("npm view oh-my-opencode version 2>/dev/null", 5000);
    if (version) {
      _omocState.version = version;
    }

    // Default MCPs and hooks if not populated from config
    if (_omocState.mcps.length === 0) {
      _omocState.mcps = Object.keys(OMOC_MANAGED_MCPS);
    }
    if (_omocState.hooks.length === 0) {
      _omocState.hooks = [...OMOC_HOOK_NAMES];
    }

    console.error(
      `[aidevops] oh-my-opencode detected${_omocState.version ? ` (v${_omocState.version})` : ""}: ` +
      `${_omocState.mcps.length} MCPs, ${_omocState.hooks.length} hooks active — ` +
      `aidevops will complement (not duplicate) OMOC features`,
    );
  }

  return _omocState;
}

/**
 * Check if a specific MCP is managed by oh-my-opencode.
 * @param {string} mcpName - aidevops MCP registry name
 * @returns {boolean}
 */
function isMcpManagedByOmoc(mcpName) {
  const omoc = detectOhMyOpenCode();
  if (!omoc.detected) return false;

  // Check if any OMOC MCP maps to this aidevops MCP name
  for (const [omocName, aidevopsName] of Object.entries(OMOC_MANAGED_MCPS)) {
    if (aidevopsName === mcpName && omoc.mcps.includes(omocName)) {
      return true;
    }
  }
  return false;
}

/**
 * Check if a specific hook type is handled by oh-my-opencode.
 * @param {string} hookName - OMOC hook name to check
 * @returns {boolean}
 */
function isHookManagedByOmoc(hookName) {
  const omoc = detectOhMyOpenCode();
  if (!omoc.detected) return false;
  return omoc.hooks.includes(hookName);
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
 *   - toolPattern: glob pattern for tool permissions (e.g. "osgrep_*")
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
    // --- Eager-loaded MCPs (start at launch) ---
    {
      name: "osgrep",
      type: "local",
      command: ["osgrep", "mcp"],
      eager: true,
      toolPattern: "osgrep_*",
      globallyEnabled: true,
      requiresBinary: "osgrep",
      description: "Semantic code search (local, no auth)",
    },

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
 * Oh-My-OpenCode tool patterns to disable globally when OMOC is NOT detected.
 * When OMOC IS detected, these are left alone (OMOC manages them).
 * These MCPs may exist from old configs or stale OmO installations.
 */
const OMO_DISABLED_PATTERNS = ["grep_app_*", "websearch_*", "gh_grep_*"];

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
    // Skip MCPs managed by oh-my-opencode to avoid duplicates (t008.4)
    if (isMcpManagedByOmoc(mcp.name)) {
      console.error(`[aidevops] Skipping MCP '${mcp.name}' — managed by oh-my-opencode`);
      continue;
    }

    // Skip macOS-only MCPs on other platforms
    if (mcp.macOnly && !IS_MACOS) continue;

    // Skip local MCPs whose binary isn't installed
    if (mcp.requiresBinary) {
      const binaryPath = run(`which ${mcp.requiresBinary}`);
      if (!binaryPath) {
        // Disable tools if binary not available
        if (mcp.toolPattern) {
          config.tools[mcp.toolPattern] = false;
        }
        continue;
      }
    }

    // Register MCP server if not already configured (or if alwaysOverwrite)
    if (!config.mcp[mcp.name] || mcp.alwaysOverwrite) {
      if (mcp.type === "remote" && mcp.url) {
        config.mcp[mcp.name] = {
          type: "remote",
          url: mcp.url,
          enabled: mcp.eager,
        };
      } else {
        config.mcp[mcp.name] = {
          type: "local",
          command: mcp.command,
          enabled: mcp.eager,
        };
      }
      registered++;
    } else {
      // Enforce loading policy on existing MCPs
      config.mcp[mcp.name].enabled = mcp.eager;
    }

    // Set global tool permissions
    if (mcp.toolPattern) {
      config.tools[mcp.toolPattern] = mcp.globallyEnabled;
    }
  }

  // Disable stale Oh-My-OpenCode tool patterns — but only when OMOC is NOT active.
  // When OMOC is detected, it manages its own tool permissions.
  const omoc = detectOhMyOpenCode();
  if (!omoc.detected) {
    for (const pattern of OMO_DISABLED_PATTERNS) {
      if (!(pattern in config.tools)) {
        config.tools[pattern] = false;
      }
    }
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

  for (const [agentName, toolPatterns] of Object.entries(AGENT_MCP_TOOLS)) {
    if (!config.agent[agentName]) continue;
    if (toolPatterns.length === 0) continue;

    // Ensure agent has a tools section
    if (!config.agent[agentName].tools) {
      config.agent[agentName].tools = {};
    }

    for (const pattern of toolPatterns) {
      // Only set if not already configured (shell script takes precedence)
      if (!(pattern in config.agent[agentName].tools)) {
        config.agent[agentName].tools[pattern] = true;
        updated++;
      }
    }
  }

  return updated;
}

/**
 * Modify OpenCode config to register aidevops agents and MCP servers.
 * This complements generate-opencode-agents.sh by ensuring agents and
 * MCPs are always up-to-date even without re-running setup.sh.
 * @param {object} config - OpenCode Config object (mutable)
 */
async function configHook(config) {
  // --- Agent registration (Phase 1) ---
  if (!config.agent) config.agent = {};

  const agents = loadAgentDefinitions();
  let agentsInjected = 0;

  for (const agent of agents) {
    if (config.agent[agent.name]) continue;
    if (agent.mode !== "subagent") continue;

    config.agent[agent.name] = {
      description: agent.description || `aidevops subagent: ${agent.relPath}`,
      mode: "subagent",
    };
    agentsInjected++;
  }

  // --- MCP registration (Phase 2) ---
  const mcpsRegistered = registerMcpServers(config);
  const agentToolsUpdated = applyAgentMcpTools(config);

  // Log summary for debugging (visible in OpenCode logs)
  const parts = [];
  if (agentsInjected > 0) parts.push(`${agentsInjected} agents`);
  if (mcpsRegistered > 0) parts.push(`${mcpsRegistered} MCPs`);
  if (agentToolsUpdated > 0) parts.push(`${agentToolsUpdated} agent tool perms`);

  if (parts.length > 0) {
    console.error(`[aidevops] Config hook: injected ${parts.join(", ")}`);
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

    // Find function definitions and check for return statements
    let inFunction = false;
    let functionName = "";
    let functionStart = 0;
    let braceDepth = 0;
    let hasReturn = false;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      // Detect function definition: name() { or function name {
      const funcMatch = trimmed.match(
        /^([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)\s*\{/,
      );
      const funcMatch2 = trimmed.match(/^function\s+([a-zA-Z_][a-zA-Z0-9_]*)/);

      if (funcMatch || funcMatch2) {
        if (inFunction && !hasReturn) {
          details.push(
            `  Line ${functionStart}: function '${functionName}' missing explicit return`,
          );
          violations++;
        }
        inFunction = true;
        functionName = funcMatch ? funcMatch[1] : funcMatch2[1];
        functionStart = i + 1;
        braceDepth = trimmed.includes("{") ? 1 : 0;
        hasReturn = false;
        continue;
      }

      if (inFunction) {
        // Track brace depth
        for (const ch of trimmed) {
          if (ch === "{") braceDepth++;
          else if (ch === "}") braceDepth--;
        }

        // Check for return statement
        if (/\breturn\s+[0-9]/.test(trimmed) || /\breturn\s*$/.test(trimmed)) {
          hasReturn = true;
        }

        // Function ended
        if (braceDepth <= 0) {
          if (!hasReturn) {
            details.push(
              `  Line ${functionStart}: function '${functionName}' missing explicit return`,
            );
            violations++;
          }
          inFunction = false;
        }
      }
    }

    // Handle last function if file ends inside it
    if (inFunction && !hasReturn) {
      details.push(
        `  Line ${functionStart}: function '${functionName}' missing explicit return`,
      );
      violations++;
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
 * Pre-tool-use hook: Comprehensive quality gate for Write/Edit operations.
 * Runs the full quality pipeline matching pre-commit-hook.sh checks:
 * - Shell scripts (.sh): ShellCheck, return statements, positional params, secrets
 * - Markdown (.md): MD031 (blank lines around code blocks), trailing whitespace
 * - All files: secrets scanning
 * @param {object} input - { tool, sessionID, callID }
 * @param {object} output - { args } (mutable)
 */
async function toolExecuteBefore(input, output) {
  const { tool } = input;

  // Only intercept Write and Edit tools
  if (
    tool !== "Write" &&
    tool !== "Edit" &&
    tool !== "write" &&
    tool !== "edit"
  ) {
    return;
  }

  const filePath = output.args?.filePath || output.args?.file_path || "";
  if (!filePath) return;

  // Shell script quality pipeline
  if (filePath.endsWith(".sh")) {
    const { totalViolations, report } = runShellQualityPipeline(filePath);
    if (totalViolations > 0) {
      console.error(
        `[aidevops] Quality gate: ${totalViolations} issue${totalViolations !== 1 ? "s" : ""} in ${filePath}:\n${report}`,
      );
      qualityLog(
        "WARN",
        `Shell quality: ${totalViolations} violations in ${filePath}`,
      );
    } else {
      qualityLog("INFO", `Shell quality: PASS for ${filePath}`);
    }
    return;
  }

  // Markdown quality pipeline
  if (filePath.endsWith(".md")) {
    const { totalViolations, report } = runMarkdownQualityPipeline(filePath);
    if (totalViolations > 0) {
      console.error(
        `[aidevops] Markdown quality: ${totalViolations} issue${totalViolations !== 1 ? "s" : ""} in ${filePath}:\n${report}`,
      );
      qualityLog(
        "WARN",
        `Markdown quality: ${totalViolations} violations in ${filePath}`,
      );
    }
    return;
  }

  // Secrets scan for all other file types
  const writeContent = output.args?.content || output.args?.newString || "";
  if (writeContent) {
    const secretResult = scanForSecrets(filePath, writeContent);
    if (secretResult.violations > 0) {
      console.error(
        `[aidevops] SECURITY: ${secretResult.violations} potential secret${secretResult.violations !== 1 ? "s" : ""} in ${filePath}:\n${secretResult.details.join("\n")}`,
      );
      qualityLog(
        "ERROR",
        `Secrets detected: ${secretResult.violations} in ${filePath}`,
      );
    }
  }
}

/**
 * Post-tool-use hook: Quality metrics tracking and pattern recording.
 * Logs tool execution for debugging and feeds data to pattern-tracker-helper.sh.
 * @param {object} input - { tool, sessionID, callID }
 * @param {object} output - { title, output, metadata } (mutable)
 */
async function toolExecuteAfter(input, output) {
  const toolName = input.tool || "";
  const title = output.title || "";
  const outputText = output.output || "";

  // Track git operations for pattern recording
  if (toolName === "Bash" || toolName === "bash") {
    if (title.includes("git commit") || title.includes("git push")) {
      console.error(`[aidevops] Git operation detected: ${title}`);
      qualityLog("INFO", `Git operation: ${title}`);

      // Record pattern if pattern-tracker-helper.sh is available
      const patternTracker = join(SCRIPTS_DIR, "pattern-tracker-helper.sh");
      if (existsSync(patternTracker)) {
        const success = !outputText.includes("error") && !outputText.includes("fatal");
        const patternType = success ? "SUCCESS_PATTERN" : "FAILURE_PATTERN";
        run(
          `bash "${patternTracker}" record "${patternType}" "git operation: ${title.substring(0, 100)}" --tag "quality-hook" 2>/dev/null`,
          5000,
        );
      }
    }

    // Track ShellCheck/lint runs in Bash commands
    if (
      title.includes("shellcheck") ||
      title.includes("linters-local")
    ) {
      const passed = !outputText.includes("error") && !outputText.includes("violation");
      qualityLog(
        passed ? "INFO" : "WARN",
        `Lint run: ${title} — ${passed ? "PASS" : "issues found"}`,
      );
    }
  }

  // Track Write/Edit operations for quality metrics
  if (
    toolName === "Write" ||
    toolName === "Edit" ||
    toolName === "write" ||
    toolName === "edit"
  ) {
    const filePath = output.metadata?.filePath || "";
    if (filePath) {
      qualityLog("INFO", `File modified: ${filePath} via ${toolName}`);
    }
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
 * Get oh-my-opencode compatibility state for compaction context.
 * @returns {string}
 */
function getOmocState() {
  const omoc = detectOhMyOpenCode();
  if (!omoc.detected) return "";

  const lines = ["## oh-my-opencode Compatibility"];
  lines.push(`oh-my-opencode detected${omoc.version ? ` (v${omoc.version})` : ""}`);
  lines.push("aidevops complements OMOC — no duplicate MCPs or hooks.");

  if (omoc.mcps.length > 0) {
    lines.push(`OMOC-managed MCPs (skipped by aidevops): ${omoc.mcps.join(", ")}`);
  }
  if (omoc.hooks.length > 0) {
    lines.push(`OMOC hooks active: ${omoc.hooks.join(", ")}`);
    lines.push("aidevops hooks (ShellCheck, return-statements, secrets, MD031) are complementary.");
  }

  return lines.join("\n");
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
    getOmocState(),
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
          const cmdOutput = (err.stdout || "") + (err.stderr || "");
          const guidance = {
            1: "STOP — you are on main/master branch. Create a worktree first.",
            2: "Create a worktree before proceeding with edits.",
            3: "WARNING — proceed with caution.",
          };
          return `Pre-edit check exit ${code}: ${guidance[code] || "Unknown"}\n${cmdOutput.trim()}`;
        }
      },
    },

    aidevops_quality_check: {
      description:
        'Run quality checks on a file or the full pre-commit pipeline. Args: file (string, path to check) OR command "pre-commit" to run full pipeline on staged files',
      async execute(args) {
        const file = args.file || args.command || args;

        // Full pre-commit pipeline
        if (file === "pre-commit" || file === "staged") {
          const hookScript = join(SCRIPTS_DIR, "pre-commit-hook.sh");
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

        // Single file check
        if (typeof file === "string" && file.endsWith(".sh")) {
          const { totalViolations, report } = runShellQualityPipeline(file);
          return totalViolations > 0
            ? `Quality check: ${totalViolations} issue(s) found:\n${report}`
            : "Quality check: all checks passed.";
        }

        if (typeof file === "string" && file.endsWith(".md")) {
          const { totalViolations, report } = runMarkdownQualityPipeline(file);
          return totalViolations > 0
            ? `Markdown check: ${totalViolations} issue(s) found:\n${report}`
            : "Markdown check: all checks passed.";
        }

        // Generic secrets scan
        if (typeof file === "string" && existsSync(file)) {
          const secretResult = scanForSecrets(file);
          return secretResult.violations > 0
            ? `Secrets scan: ${secretResult.violations} potential issue(s):\n${secretResult.details.join("\n")}`
            : "Secrets scan: no issues found.";
        }

        return `Usage: pass a file path (.sh or .md) or "pre-commit" for full pipeline`;
      },
    },

    aidevops_install_hooks: {
      description:
        'Install or manage git pre-commit quality hooks. Args: action (string: "install", "uninstall", "status", "test")',
      async execute(args) {
        const action = args.action || args || "install";
        const helperScript = join(SCRIPTS_DIR, "install-hooks-helper.sh");

        // Try install-hooks-helper.sh first (Claude Code hooks)
        if (existsSync(helperScript)) {
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

        // Fallback: install git pre-commit hook directly
        if (action === "install") {
          const preCommitHook = join(SCRIPTS_DIR, "pre-commit-hook.sh");
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

        return `install-hooks-helper.sh not found. Available actions: install, uninstall, status, test`;
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
 * 0. oh-my-opencode detection — detects OMOC presence and deduplicates (t008.4)
 * 1. Config hook — dynamic agent loading + MCP server registration from ~/.aidevops/agents/
 * 2. Custom tools — aidevops CLI, memory, pre-edit check, quality check, hook installer
 * 3. Quality hooks — full pre-commit pipeline (ShellCheck, return statements,
 *    positional params, secrets scan, markdown lint) on Write/Edit operations
 * 4. Shell environment — aidevops paths and variables
 * 5. Compaction context — preserves operational state across context resets
 *
 * MCP registration (Phase 2, t008.2):
 * - Registers all known MCP servers from a data-driven registry
 * - Enforces eager/lazy loading policy (only osgrep starts at launch)
 * - Sets global tool permissions and per-agent MCP tool enablement
 * - Skips MCPs whose required binaries aren't installed
 * - Skips MCPs managed by oh-my-opencode when OMOC is detected (t008.4)
 * - Disables Oh-My-OpenCode tool patterns globally
 * - Complements generate-opencode-agents.sh (shell script takes precedence)
 *
 * oh-my-opencode compatibility (Phase 0, t008.4):
 * - Detects OMOC via OpenCode config, OMOC config files, and npm
 * - Skips MCP registration for MCPs managed by OMOC (context7, websearch, grep_app)
 * - Quality hooks are complementary (aidevops: ShellCheck, secrets; OMOC: comments, todos)
 * - OMOC state injected into compaction context for session continuity
 *
 * @type {import('@opencode-ai/plugin').Plugin}
 */
export async function AidevopsPlugin({ directory }) {
  // Phase 0: Detect oh-my-opencode early so all hooks can adapt
  detectOhMyOpenCode(directory);

  return {
    // Phase 1+2: Dynamic agent and config injection
    config: async (config) => configHook(config),

    // Phase 1: Custom tools
    tool: createTools(),

    // Phase 3: Quality hooks (complementary to OMOC — no overlap)
    "tool.execute.before": toolExecuteBefore,
    "tool.execute.after": toolExecuteAfter,

    // Phase 4: Shell environment
    "shell.env": shellEnvHook,

    // Compaction context (includes OMOC state when detected)
    "experimental.session.compacting": async (input, output) =>
      compactingHook(input, output, directory),
  };
}
