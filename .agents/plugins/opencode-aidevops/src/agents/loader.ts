import { readdirSync, readFileSync, existsSync, statSync } from "fs";
import { join, relative } from "path";
import matter from "gray-matter";
import type { PluginConfig } from "../config/schema.js";

/**
 * Agent definition parsed from a markdown file with YAML frontmatter.
 */
export interface AgentDefinition {
  name: string;
  description: string;
  mode: "primary" | "subagent";
  tools: Record<string, boolean>;
  model?: string;
  content: string;
  path: string;
  namespace: string;
}

/**
 * Load all agents from the aidevops agents directory.
 *
 * Scans ~/.aidevops/agents/ for markdown files with YAML frontmatter.
 * Respects the 3-tier directory structure:
 *   - Root *.md files → primary agents
 *   - Subdirectory *.md files → subagents
 *   - Plugin namespace dirs (from plugins.json) → plugin agents
 *   - custom/ and draft/ → user agents
 *
 * @param config - Plugin configuration
 * @returns Array of parsed agent definitions
 */
export function loadAgents(config: PluginConfig): AgentDefinition[] {
  const agentsDir = config.agentsDir;

  if (!existsSync(agentsDir)) {
    return [];
  }

  const agents: AgentDefinition[] = [];
  const excludeSet = new Set(config.excludeDirs);
  const disabledSet = new Set(config.disabledAgents);

  // Load root-level agents (primary agents like build-plus.md, aidevops.md)
  loadAgentsFromDir(agentsDir, "primary", "core", agents, disabledSet);

  if (!config.loadSubagents) {
    return agents.slice(0, config.maxAgents);
  }

  // Scan subdirectories for subagents
  const entries = readdirSafe(agentsDir);
  for (const entry of entries) {
    if (excludeSet.has(entry)) {
      continue;
    }

    const fullPath = join(agentsDir, entry);
    if (!isDirectory(fullPath)) {
      continue;
    }

    // Determine namespace: custom/, draft/, or plugin namespaces get their name
    // Core subdirs (aidevops/, tools/, services/, etc.) stay as "core"
    const coreSubdirs = new Set([
      "aidevops",
      "tools",
      "services",
      "workflows",
      "memory",
      "content",
      "seo",
      "hooks",
      "prompts",
    ]);
    const namespace = coreSubdirs.has(entry) ? "core" : entry;

    loadAgentsFromDir(fullPath, "subagent", namespace, agents, disabledSet);

    // Recurse one level deeper for nested subagents (e.g., tools/browser/*.md)
    const subEntries = readdirSafe(fullPath);
    for (const subEntry of subEntries) {
      if (excludeSet.has(subEntry)) {
        continue;
      }
      const subPath = join(fullPath, subEntry);
      if (isDirectory(subPath)) {
        loadAgentsFromDir(subPath, "subagent", namespace, agents, disabledSet);
      }
    }

    if (agents.length >= config.maxAgents) {
      break;
    }
  }

  return agents.slice(0, config.maxAgents);
}

/**
 * Load agents from a single directory.
 */
function loadAgentsFromDir(
  dir: string,
  defaultMode: "primary" | "subagent",
  namespace: string,
  agents: AgentDefinition[],
  disabledSet: Set<string>,
): void {
  const files = readdirSafe(dir);

  for (const file of files) {
    if (!file.endsWith(".md")) {
      continue;
    }

    const name = file.replace(/\.md$/, "");
    if (disabledSet.has(name)) {
      continue;
    }

    const filePath = join(dir, file);
    const agent = parseAgentFile(filePath, name, defaultMode, namespace);
    if (agent) {
      agents.push(agent);
    }
  }
}

/**
 * Parse a single markdown agent file.
 * Extracts YAML frontmatter for metadata and the body as content.
 *
 * @returns AgentDefinition or null if the file cannot be parsed
 */
function parseAgentFile(
  filePath: string,
  name: string,
  defaultMode: "primary" | "subagent",
  namespace: string,
): AgentDefinition | null {
  try {
    const raw = readFileSync(filePath, "utf-8");
    const { data, content } = matter(raw);

    // Skip files without meaningful content (< 50 chars after frontmatter)
    if (content.trim().length < 50) {
      return null;
    }

    const mode = data.mode === "primary" ? "primary" : defaultMode;
    const tools: Record<string, boolean> =
      typeof data.tools === "object" && data.tools !== null
        ? (data.tools as Record<string, boolean>)
        : {};

    return {
      name,
      description: typeof data.description === "string" ? data.description : "",
      mode,
      tools,
      model: typeof data.model === "string" ? data.model : undefined,
      content: content.trim(),
      path: filePath,
      namespace,
    };
  } catch {
    // Silently skip unparseable files — don't crash the plugin
    return null;
  }
}

/**
 * Get a summary of loaded agents for logging/debugging.
 */
export function getAgentSummary(agents: AgentDefinition[]): string {
  const byNamespace = new Map<string, number>();
  let primaryCount = 0;
  let subagentCount = 0;

  for (const agent of agents) {
    const count = byNamespace.get(agent.namespace) ?? 0;
    byNamespace.set(agent.namespace, count + 1);
    if (agent.mode === "primary") {
      primaryCount++;
    } else {
      subagentCount++;
    }
  }

  const lines = [
    `Loaded ${agents.length} agents (${primaryCount} primary, ${subagentCount} subagents)`,
  ];

  for (const [ns, count] of byNamespace.entries()) {
    lines.push(`  ${ns}: ${count}`);
  }

  return lines.join("\n");
}

/**
 * Load plugin namespace directories from plugins.json.
 * Returns the set of namespace names that are plugin directories.
 */
export function loadPluginNamespaces(): Set<string> {
  const pluginsPath = join(
    process.env.HOME ?? "",
    ".config",
    "aidevops",
    "plugins.json",
  );

  if (!existsSync(pluginsPath)) {
    return new Set();
  }

  try {
    const raw = readFileSync(pluginsPath, "utf-8");
    const data = JSON.parse(raw);
    const plugins = Array.isArray(data.plugins) ? data.plugins : [];
    const namespaces = new Set<string>();

    for (const plugin of plugins) {
      if (
        typeof plugin === "object" &&
        plugin !== null &&
        typeof plugin.namespace === "string" &&
        plugin.enabled !== false
      ) {
        namespaces.add(plugin.namespace);
      }
    }

    return namespaces;
  } catch {
    return new Set();
  }
}

/** Safe readdir that returns empty array on error */
function readdirSafe(dir: string): string[] {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

/** Check if a path is a directory */
function isDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}
