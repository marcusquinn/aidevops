import { existsSync, readdirSync } from "fs";
import { platform } from "os";
import { join } from "path";

const IS_MACOS = platform() === "darwin";

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
  shopify: ["shopify-dev-mcp_*"],
};

/**
 * Collect leaf agent names from a pipe-separated key_files string.
 * @param {string} keyFiles - e.g. "dataforseo|serper|semrush"
 * @param {string} purpose - Description for the agent entry
 * @param {Array} agents - Mutable agents array
 * @param {Set} seen - Dedup set
 */
export function collectLeafAgents(keyFiles, purpose, agents, seen) {
  for (const leaf of keyFiles.split("|")) {
    const name = leaf.trim();
    if (!name || SKIP_NAMES.has(name) || name.endsWith("-skill")) continue;
    if (seen.has(name)) continue;
    seen.add(name);
    agents.push({ name, description: purpose });
  }
}

/**
 * Parse a TOON subagents block into agent entries.
 * Each line: folder,purpose,keyfile1|keyfile2|...
 * @param {string} blockText - Raw text from the TOON block
 * @returns {Array<{name: string, description: string}>}
 */
export function parseToonSubagentBlock(blockText) {
  const agents = [];
  const seen = new Set();

  for (const line of blockText.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    const parts = trimmed.split(",");
    if (parts.length < 3) continue;

    const folder = parts[0] || "";
    if (folder.includes("references/") || folder.includes("loop-state/")) continue;

    collectLeafAgents(parts.slice(2).join(","), parts[1] || "", agents, seen);
  }

  return agents;
}

/**
 * Try to register a .md file entry as a discovered agent.
 * @param {object} entry - Dirent object
 * @param {string} folderDesc - Description fallback
 * @param {Array} agents - Mutable agents array
 * @param {Set} seen - Dedup set
 */
function tryRegisterMdAgent(entry, folderDesc, agents, seen) {
  if (!entry.isFile() || !entry.name.endsWith(".md")) return;
  const name = entry.name.replace(/\.md$/, "");
  if (SKIP_NAMES.has(name) || name.endsWith("-skill")) return;
  if (seen.has(name)) return;
  seen.add(name);
  agents.push({ name, description: `aidevops subagent: ${folderDesc}` });
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
    } else {
      tryRegisterMdAgent(entry, folderDesc, agents, seen);
    }
  }
}

/**
 * Fallback: discover agents from directory names only (no file reads).
 * Lists .md filenames in known subdirectories — O(n) readdirSync calls
 * where n = number of subdirectories (~11), NOT number of files.
 * Each readdirSync returns filenames without reading file contents.
 * @param {string} agentsDir
 * @returns {Array<{name: string, description: string}>}
 */
function loadAgentsFallback(agentsDir) {
  if (!existsSync(agentsDir)) return [];

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
    scanDirNames(join(agentsDir, subdir), subdir, agents, seen);
  }

  return agents;
}

/**
 * Parse subagent-index.toon and return leaf agent names with descriptions.
 * Reads ONE file instead of 500+. Returns entries like:
 *   { name: "dataforseo", description: "Search optimization - keywords..." }
 * @param {string} agentsDir
 * @param {(filepath: string) => string} readIfExists
 * @returns {Array<{name: string, description: string}>}
 */
export function loadAgentIndex(agentsDir, readIfExists) {
  const indexPath = join(agentsDir, "subagent-index.toon");
  const content = readIfExists(indexPath);
  if (!content) return loadAgentsFallback(agentsDir);

  const subagentMatch = content.match(
    /<!--TOON:subagents\[\d+\]\{[^}]+\}:\n([\s\S]*?)-->/,
  );
  if (!subagentMatch) return loadAgentsFallback(agentsDir);

  const agents = parseToonSubagentBlock(subagentMatch[1]);

  // Also parse top-level agents block (Build+, Automate, etc.)
  // Format: name,file,purpose,model_tier — one per line
  const topLevelMatch = content.match(
    /<!--TOON:agents\[\d+\]\{[^}]+\}:\n([\s\S]*?)-->/,
  );
  if (topLevelMatch) {
    const seen = new Set(agents.map((a) => a.name));
    for (const line of topLevelMatch[1].split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const parts = trimmed.split(",");
      if (parts.length < 3) continue;
      const name = parts[0].trim();
      const purpose = parts[2].trim();
      if (name && !seen.has(name)) {
        seen.add(name);
        agents.push({ name, description: purpose });
      }
    }
  }

  return agents;
}

/**
 * Apply tool patterns to a single agent config entry.
 * Only sets tools not already configured (shell script takes precedence).
 * @param {object} agentEntry - Mutable agent config object
 * @param {string[]} toolPatterns - Tool patterns to enable
 * @returns {number} Number of tools newly enabled
 */
export function applyToolPatternsToAgent(agentEntry, toolPatterns) {
  let count = 0;
  if (!agentEntry.tools) {
    agentEntry.tools = {};
  }
  for (const pattern of toolPatterns) {
    if (!(pattern in agentEntry.tools)) {
      agentEntry.tools[pattern] = true;
      count++;
    }
  }
  return count;
}

/**
 * Apply per-agent MCP tool permissions.
 * Ensures subagents that need specific MCP tools have them enabled
 * in their agent config, even if the tools are disabled globally.
 *
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} Number of agents updated
 */
export function applyAgentMcpTools(config) {
  if (!config.agent) return 0;

  let updated = 0;

  for (const [mcpAgentName, toolPatterns] of Object.entries(AGENT_MCP_TOOLS)) {
    if (toolPatterns.length === 0) continue;

    const matchingKeys = Object.keys(config.agent).filter(
      (key) => key === mcpAgentName || key.endsWith("/" + mcpAgentName),
    );

    for (const matchKey of matchingKeys) {
      updated += applyToolPatternsToAgent(config.agent[matchKey], toolPatterns);
    }
  }

  return updated;
}
