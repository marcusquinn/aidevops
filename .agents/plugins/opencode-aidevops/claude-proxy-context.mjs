// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Request → Claude CLI context translation for the Claude proxy.
 *
 * This module owns everything needed to turn an OpenAI-compatible request
 * into the concrete `claude` subprocess invocation:
 *   - framework system prompt cache (build.txt + AGENTS.md)
 *   - per-agent system prompt cache (~/.aidevops/agents/<agent>.md)
 *   - per-agent MCP config generation
 *   - chat message parsing (system vs conversation)
 *   - request → (agentName, model, effortLevel) resolution
 *   - final `claude` argv builder
 *
 * Extracted from claude-proxy.mjs as part of t2070 to drop file complexity.
 */

import { mkdirSync, readFileSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

// ---------------------------------------------------------------------------
// Framework system prompt cache
// ---------------------------------------------------------------------------

/** @type {string | null} */
let _frameworkPromptCache = null;

/**
 * Load and cache the AI DevOps framework prompt (build.txt + AGENTS.md).
 * Appended to Claude CLI's default system prompt via --append-system-prompt
 * so the CLI agent behaves consistently with our OpenCode agent configuration.
 * Files are read from ~/.aidevops/agents/ (the deployed copy).
 */
export function getFrameworkPrompt() {
  if (_frameworkPromptCache !== null) return _frameworkPromptCache;

  const agentsDir = join(homedir(), ".aidevops", "agents");
  const files = [
    join(agentsDir, "prompts", "build.txt"),
    join(agentsDir, "AGENTS.md"),
  ];

  const parts = [];
  for (const filePath of files) {
    try {
      const content = readFileSync(filePath, "utf-8").trim();
      if (content) parts.push(content);
    } catch {
      // File may not exist in minimal installations
    }
  }

  _frameworkPromptCache = parts.length > 0 ? parts.join("\n\n---\n\n") : "";
  if (_frameworkPromptCache) {
    console.error(
      `[aidevops] Claude proxy: loaded framework prompt (${_frameworkPromptCache.length} chars from ${parts.length} files)`,
    );
  }
  return _frameworkPromptCache;
}

// ---------------------------------------------------------------------------
// Agent file mapping + per-agent prompt cache
// ---------------------------------------------------------------------------

/**
 * Map of known agent identifiers to their file names in ~/.aidevops/agents/.
 * The proxy selects an agent based on:
 *   1. X-Agent header in the request
 *   2. The middle component of OpenCode's `provider/agent/model` routing key
 *      (e.g. `claudecli/seo/opus` → agent="seo")
 *   3. Default: "build-plus" (the primary interactive agent)
 */
export const AGENT_FILES = {
  "build-plus": "build-plus.md",
  "automate": "automate.md",
  "seo": "seo.md",
  "content": "content.md",
  "research": "research.md",
  "legal": "legal.md",
  "business": "business.md",
};

/** @type {Map<string, string>} agent name → cached prompt content */
const _agentPromptCache = new Map();

/**
 * Load the agent-specific prompt file. Falls back to build-plus.md.
 * @param {string} [agentName]
 * @returns {string}
 */
export function getAgentPrompt(agentName) {
  const name = agentName && AGENT_FILES[agentName] ? agentName : "build-plus";
  if (_agentPromptCache.has(name)) return _agentPromptCache.get(name);

  const filePath = join(homedir(), ".aidevops", "agents", AGENT_FILES[name]);
  let content = "";
  try {
    content = readFileSync(filePath, "utf-8").trim();
  } catch {
    // agent file not found — use empty
  }
  _agentPromptCache.set(name, content);
  return content;
}

// ---------------------------------------------------------------------------
// MCP config generation — per-agent lazy loading
// ---------------------------------------------------------------------------

/**
 * Agent → MCP server mapping. Only the MCPs listed here are passed via
 * --mcp-config for the corresponding agent. Agents not listed get no
 * extra MCPs (Claude CLI's built-in tools are always available).
 *
 * Mirrors the OpenCode pattern: MCPs disabled by default, enabled per-agent.
 */
const AGENT_MCPS = {
  "build-plus": ["context7"],
  "seo": ["context7", "gsc", "dataforseo"],
  "automate": ["context7"],
  "content": ["context7"],
  "research": ["context7"],
};

/**
 * MCP server definitions in Claude CLI --mcp-config format.
 * Only servers that might be needed per-agent are included here.
 * Claude CLI's global config (~/.claude.json) handles always-on MCPs.
 */
function getMcpDefinition(name) {
  const defs = {
    context7: { command: "npx", args: ["-y", "@upstash/context7-mcp@latest"], type: "stdio" },
    gsc: {
      command: "/bin/bash",
      args: ["-c", "GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS:-~/.config/aidevops/gsc-credentials.json} npx -y mcp-server-gsc"],
      type: "stdio",
    },
    dataforseo: {
      command: "/bin/bash",
      args: ["-c", "source ~/.config/aidevops/credentials.sh && DATAFORSEO_USERNAME=$DATAFORSEO_USERNAME DATAFORSEO_PASSWORD=$DATAFORSEO_PASSWORD npx -y dataforseo-mcp-server"],
      type: "stdio",
    },
    shadcn: { command: "npx", args: ["shadcn@latest", "mcp"], type: "stdio" },
    playwright: { command: "npx", args: ["-y", "@playwright/mcp@latest"], type: "stdio" },
  };
  return defs[name] || null;
}

/** @type {Map<string, string>} agent name → path to generated MCP config file */
const _mcpConfigFileCache = new Map();

/**
 * Generate a temporary MCP config JSON file for the given agent.
 * Returns the file path, or null if no agent-specific MCPs are needed.
 * @param {string} [agentName]
 * @returns {string | null}
 */
export function getMcpConfigForAgent(agentName) {
  const name = agentName && AGENT_MCPS[agentName] ? agentName : "build-plus";
  const mcpNames = AGENT_MCPS[name];
  if (!mcpNames || mcpNames.length === 0) return null;

  if (_mcpConfigFileCache.has(name)) return _mcpConfigFileCache.get(name);

  const mcpServers = {};
  for (const mcpName of mcpNames) {
    const def = getMcpDefinition(mcpName);
    if (def) mcpServers[mcpName] = def;
  }

  if (Object.keys(mcpServers).length === 0) return null;

  const configDir = join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  mkdirSync(configDir, { recursive: true });
  const configPath = join(configDir, `claude-cli-mcp-${name}.json`);
  writeFileSync(configPath, JSON.stringify({ mcpServers }, null, 2), "utf-8");
  _mcpConfigFileCache.set(name, configPath);
  console.error(`[aidevops] Claude proxy: generated MCP config for agent=${name} at ${configPath}`);
  return configPath;
}

// ---------------------------------------------------------------------------
// Chat message parsing
// ---------------------------------------------------------------------------

function extractTextContent(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part) => part && typeof part === "object" && part.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("\n");
}

function sanitizeClaudeCliSystemPrompt(text) {
  return text.replace(/<directories>\s*([\s\S]*?)\s*<\/directories>/g, (_m, inner) => {
    const content = String(inner || "").trim();
    return content ? `Directories:\n${content}` : "";
  });
}

function renderConversationPrompt(conversation) {
  if (conversation.length === 0) return "Continue the conversation helpfully.";
  return [
    "Continue this conversation naturally.",
    "",
    ...conversation.map((message) => `${message.role.toUpperCase()}:\n${message.text}`),
  ].join("\n\n");
}

/**
 * Parse OpenAI chat-completion messages into a `{ systemPrompt, prompt }`
 * pair. System messages are concatenated; user/assistant messages are
 * rendered as a transcript.
 */
export function parseChatMessages(messages) {
  const systemParts = [];
  const conversation = [];

  for (const message of messages || []) {
    const text = extractTextContent(message?.content);
    if (!text.trim()) continue;
    if (message.role === "system") {
      systemParts.push(text);
      continue;
    }
    conversation.push({ role: message.role || "user", text });
  }

  return {
    systemPrompt: sanitizeClaudeCliSystemPrompt(systemParts.join("\n\n").trim()),
    prompt: renderConversationPrompt(conversation),
  };
}

// ---------------------------------------------------------------------------
// Agent + model + effort resolution
// ---------------------------------------------------------------------------

const MODEL_ALIASES = {
  haiku: "claude-haiku-4-5",
  sonnet: "claude-sonnet-4-6",
  opus: "claude-opus-4-6",
};

/**
 * Resolve the agent name + concrete model id from an OpenCode request.
 * Honours the `X-Agent` header and OpenCode's `provider/agent/model` routing
 * suffix (e.g. `claudecli/seo/opus` → agent=seo, model=claude-opus-4-6).
 */
export function resolveAgentAndModel(req, incoming) {
  let agentName = req.headers.get("x-agent") || null;
  let resolvedModel = incoming.model;

  if (typeof incoming.model === "string" && incoming.model.includes("/")) {
    const parts = incoming.model.split("/");
    if (parts.length >= 2 && AGENT_FILES[parts[1]]) {
      agentName = agentName || parts[1];
    }
    const modelSuffix = parts[parts.length - 1];
    resolvedModel = MODEL_ALIASES[modelSuffix] || incoming.model;
  }

  return { agentName: agentName || "build-plus", resolvedModel };
}

/** Extract the OpenAI-style reasoning_effort field if it's a known level. */
export function resolveEffortLevel(incoming) {
  const EFFORT_LEVELS = new Set(["low", "medium", "high", "max"]);
  if (typeof incoming.reasoning_effort === "string" && EFFORT_LEVELS.has(incoming.reasoning_effort)) {
    return incoming.reasoning_effort;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Claude CLI argv builder
// ---------------------------------------------------------------------------

/**
 * Build the argv list to pass to `claude` for a given request body.
 * The body must contain `model`, `agentName`, `prompt`, optional `effortLevel`.
 */
export function buildClaudeArgs(body, systemPrompt, streaming) {
  const agentsDir = join(homedir(), ".aidevops", "agents");
  const agentName = body.agentName || "build-plus";
  const args = ["-p", "--model", body.model];

  if (body.effortLevel) {
    args.push("--effort", body.effortLevel);
  }

  args.push(
    "--permission-mode",
    "default",
    "--no-session-persistence",
    "--add-dir",
    agentsDir,
  );

  // Agent-specific MCP config (lazy loading — only needed MCPs start)
  const mcpConfig = getMcpConfigForAgent(agentName);
  if (mcpConfig) {
    args.push("--mcp-config", mcpConfig);
  }

  // Combine: framework base (build.txt + AGENTS.md) + agent prompt + request system prompt.
  // Framework and agent go first (static), OpenCode's context-specific prompt last.
  const frameworkPrompt = getFrameworkPrompt();
  const agentPrompt = getAgentPrompt(agentName);
  const combinedPrompt = [frameworkPrompt, agentPrompt, systemPrompt].filter(Boolean).join("\n\n");
  if (combinedPrompt) {
    args.push("--append-system-prompt", combinedPrompt);
  }

  if (streaming) {
    args.push(
      "--verbose",
      "--output-format",
      "stream-json",
      "--include-partial-messages",
      "--include-hook-events",
    );
  } else {
    args.push("--output-format", "json");
  }

  args.push(body.prompt);
  return args;
}
