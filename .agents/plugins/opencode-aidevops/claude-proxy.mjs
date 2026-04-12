import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { spawn, spawnSync } from "child_process";
import { homedir } from "os";
import { dirname, join } from "path";
import { ensureValidToken, getAccounts } from "./oauth-pool.mjs";

const CLAUDE_PROXY_DEFAULT_PORT = parseInt(process.env.CLAUDE_PROXY_PORT || "32125", 10);
const CLAUDE_PROVIDER_ID = "claudecli";
const OPENCODE_CONFIG_PATH = join(homedir(), ".config", "opencode", "opencode.json");
const SSE_HEADERS = {
  "Content-Type": "text/event-stream",
  "Cache-Control": "no-cache",
  Connection: "keep-alive",
};

/** @type {ReturnType<Bun["serve"]> | null} */
let proxyServer = null;
/** @type {number | null} */
let proxyPort = null;
/** @type {boolean} */
let proxyStarting = false;

// ---------------------------------------------------------------------------
// Framework system prompt — loaded once and cached
// ---------------------------------------------------------------------------

/** @type {string | null} */
let _frameworkPromptCache = null;

/**
 * Load and cache the AI DevOps framework prompt (build.txt + AGENTS.md + main agent).
 * Appended to Claude CLI's default system prompt via --append-system-prompt so
 * the CLI agent behaves consistently with our OpenCode agent configuration.
 * Files are read from ~/.aidevops/agents/ (the deployed copy).
 */
function getFrameworkPrompt() {
  if (_frameworkPromptCache !== null) return _frameworkPromptCache;

  const agentsDir = join(homedir(), ".aidevops", "agents");
  // Framework base only — agent-specific prompt is added separately
  // via getAgentPrompt() based on per-request agent selection.
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
// Agent selection — pick the right agent file for the system prompt
// ---------------------------------------------------------------------------

/**
 * Map of known agent identifiers to their file names in ~/.aidevops/agents/.
 * The proxy selects an agent based on:
 *   1. X-Agent header in the request (e.g., "build-plus", "automate", "seo")
 *   2. Default: "build-plus" (the primary interactive agent)
 */
const AGENT_FILES = {
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
 * Load the agent-specific prompt file.  Falls back to build-plus.md.
 * @param {string} [agentName]
 * @returns {string}
 */
function getAgentPrompt(agentName) {
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
 * Agent → MCP server mapping.  Only the MCPs listed here are passed via
 * --mcp-config for the corresponding agent.  Agents not listed get no
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
function getMcpConfigForAgent(agentName) {
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
// Account rotation with rate-limit tracking
// ---------------------------------------------------------------------------

/** Map<email, expiryTimestamp> — accounts known to be rate-limited. */
const rateLimitedAccounts = new Map();

/** Default cooldown (ms) before retrying a rate-limited account. */
const RATE_LIMIT_COOLDOWN_MS = 5 * 60 * 1000; // 5 minutes

function sortAccountsByPriority(accounts) {
  return [...accounts].sort((a, b) => {
    const pa = Number(a?.priority || 0);
    const pb = Number(b?.priority || 0);
    if (pa !== pb) return pb - pa;
    return (a?.email || "").localeCompare(b?.email || "");
  });
}

/**
 * Mark an account as rate-limited so subsequent requests skip it.
 * @param {string} email
 * @param {string} [resetsAt] - optional ISO/epoch from Claude's rate_limit_event
 */
function markAccountRateLimited(email, resetsAt) {
  let expiry = Date.now() + RATE_LIMIT_COOLDOWN_MS;
  if (resetsAt) {
    const parsed = Number(resetsAt) > 1e9 ? Number(resetsAt) * 1000 : Date.parse(resetsAt);
    if (!isNaN(parsed) && parsed > Date.now()) {
      expiry = parsed;
    }
  }
  rateLimitedAccounts.set(email, expiry);
  console.error(`[aidevops] Claude proxy: account ${email} rate-limited until ${new Date(expiry).toISOString()}`);
}

function isAccountRateLimited(email) {
  const expiry = rateLimitedAccounts.get(email);
  if (!expiry) return false;
  if (Date.now() >= expiry) {
    rateLimitedAccounts.delete(email);
    return false;
  }
  return true;
}

/**
 * Get all available accounts with valid tokens, skipping rate-limited ones.
 * Returns array of { email, token } in priority order.
 */
async function getAvailableAccounts() {
  const accounts = sortAccountsByPriority(getAccounts("anthropic"));
  const available = [];
  for (const account of accounts) {
    const email = account?.email || "unknown";
    if (isAccountRateLimited(email)) {
      continue;
    }
    const token = await ensureValidToken("anthropic", account);
    if (token) {
      available.push({ email, token });
    }
  }
  return available;
}

function buildChildEnvWithToken(token) {
  const childEnv = { ...process.env };
  delete childEnv.ANTHROPIC_API_KEY;
  childEnv.CLAUDE_CODE_OAUTH_TOKEN = token;
  return childEnv;
}

/**
 * Detect rate-limit signals in Claude CLI JSON output.
 * @param {object} parsed - parsed JSON from Claude CLI
 * @returns {string|null} - resetsAt value if rate-limited, null otherwise
 */
function detectRateLimitJson(parsed) {
  if (parsed?.is_error && typeof parsed?.result === "string" && parsed.result.includes("hit your limit")) {
    return null; // rate-limited but no explicit reset time in JSON mode
  }
  return undefined; // not rate-limited
}

/**
 * Detect rate-limit signals in a stream-json event line.
 * @param {object} event - parsed stream event
 * @returns {{ rateLimited: boolean, resetsAt?: string }} 
 */
function detectRateLimitStream(event) {
  if (event?.type === "rate_limit_event") {
    return { rateLimited: true, resetsAt: event?.rate_limit_info?.resetsAt };
  }
  if (event?.type === "assistant" && event?.error === "rate_limit") {
    return { rateLimited: true };
  }
  return { rateLimited: false };
}

function isClaudeCliAvailable() {
  try {
    const result = spawnSync("claude", ["--version"], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 3000,
    });
    return result.status === 0 && result.stdout.trim().length > 0;
  } catch {
    return false;
  }
}

function getClaudeProxyModels() {
  return [
    {
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5 (via Claude CLI)",
      reasoning: true,
      contextWindow: 200000,
      maxTokens: 32000,
    },
    {
      id: "claude-sonnet-4-6",
      name: "Claude Sonnet 4.6 (via Claude CLI)",
      reasoning: true,
      contextWindow: 200000,
      maxTokens: 64000,
    },
    {
      id: "claude-opus-4-6",
      name: "Claude Opus 4.6 (via Claude CLI)",
      reasoning: true,
      contextWindow: 200000,
      maxTokens: 32000,
    },
  ];
}

function buildClaudeProviderModels(models) {
  const entries = {};
  for (const model of models) {
    entries[model.id] = {
      name: model.name,
      attachment: false,
      tool_call: false,
      temperature: true,
      reasoning: model.reasoning || false,
      modalities: { input: ["text"], output: ["text"] },
      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
      limit: {
        context: model.contextWindow || 200000,
        output: model.maxTokens || 32000,
      },
      family: "claudecli",
    };
  }
  return entries;
}

export function registerClaudeProvider(config, port, models) {
  if (!config.provider) config.provider = {};

  const providerModels = buildClaudeProviderModels(models);
  const baseURL = `http://127.0.0.1:${port}/v1`;
  const newProvider = {
    name: "Claude CLI (via aidevops proxy)",
    npm: "@ai-sdk/openai-compatible",
    api: baseURL,
    models: providerModels,
  };

  const existing = config.provider[CLAUDE_PROVIDER_ID];
  if (!existing || JSON.stringify(existing) !== JSON.stringify(newProvider)) {
    config.provider[CLAUDE_PROVIDER_ID] = newProvider;
    return true;
  }

  return false;
}

function persistClaudeProvider(port, models) {
  let config = {};
  try {
    config = JSON.parse(readFileSync(OPENCODE_CONFIG_PATH, "utf-8"));
  } catch (err) {
    if (err.code !== "ENOENT") {
      console.error(`[aidevops] Claude proxy: cannot read opencode.json: ${err.message}`);
      return;
    }
  }

  if (!config.provider) config.provider = {};
  config.provider[CLAUDE_PROVIDER_ID] = {
    name: "Claude CLI (via aidevops proxy)",
    npm: "@ai-sdk/openai-compatible",
    api: `http://127.0.0.1:${port}/v1`,
    models: buildClaudeProviderModels(models),
  };

  try {
    mkdirSync(dirname(OPENCODE_CONFIG_PATH), { recursive: true });
    writeFileSync(OPENCODE_CONFIG_PATH, JSON.stringify(config, null, 2) + "\n", "utf-8");
    console.error(`[aidevops] Claude proxy: persisted ${models.length} models to opencode.json (port ${port})`);
  } catch (err) {
    console.error(`[aidevops] Claude proxy: failed to write opencode.json: ${err.message}`);
  }
}

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

function parseChatMessages(messages) {
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

function renderConversationPrompt(conversation) {
  if (conversation.length === 0) return "Continue the conversation helpfully.";
  return [
    "Continue this conversation naturally.",
    "",
    ...conversation.map((message) => `${message.role.toUpperCase()}:\n${message.text}`),
  ].join("\n\n");
}

function buildClaudeArgs(body, systemPrompt, streaming) {
  const agentsDir = join(homedir(), ".aidevops", "agents");
  const agentName = body.agentName || "build-plus";
  const args = [
    "-p",
    "--model",
    body.model,
    "--permission-mode",
    "default",
    "--no-session-persistence",
    "--add-dir",
    agentsDir,
  ];

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

async function runClaudeJsonWithAccount(body, directory, account) {
  const childEnv = buildChildEnvWithToken(account.token);
  const child = spawn("claude", buildClaudeArgs(body, body.systemPrompt, false), {
    cwd: directory,
    env: childEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });

  const stdoutChunks = [];
  const stderrChunks = [];

  child.stdout.on("data", (chunk) => stdoutChunks.push(chunk));
  child.stderr.on("data", (chunk) => stderrChunks.push(chunk));

  const exitCode = await new Promise((resolve) => child.on("close", resolve));
  const stdout = Buffer.concat(stdoutChunks).toString("utf-8").trim();
  const stderr = Buffer.concat(stderrChunks).toString("utf-8").trim();

  if (!stdout) {
    throw new Error(stderr || `claude exited with status ${exitCode}`);
  }

  const parsed = JSON.parse(stdout);

  // Check for rate limit in JSON response
  const rateLimitResult = detectRateLimitJson(parsed);
  if (rateLimitResult !== undefined) {
    markAccountRateLimited(account.email, rateLimitResult);
    return { rateLimited: true };
  }

  if (exitCode !== 0) {
    throw new Error(parsed.result || stderr || `claude exited with status ${exitCode}`);
  }

  return {
    rateLimited: false,
    content: parsed.result || "",
    usage: parsed.usage || {},
  };
}

async function runClaudeJson(body, directory) {
  const accounts = await getAvailableAccounts();
  if (accounts.length === 0) {
    throw new Error("No Anthropic OAuth pool accounts available (all rate-limited or no valid tokens)");
  }

  for (const account of accounts) {
    console.error(`[aidevops] Claude proxy: trying account ${account.email} (json mode)`);
    const result = await runClaudeJsonWithAccount(body, directory, account);
    if (!result.rateLimited) {
      return result;
    }
    console.error(`[aidevops] Claude proxy: account ${account.email} rate-limited, trying next...`);
  }

  throw new Error("All Anthropic OAuth pool accounts are rate-limited");
}

function createOpenAIChunk(id, created, model, delta, finishReason = null) {
  return {
    id,
    object: "chat.completion.chunk",
    created,
    model,
    choices: [{ index: 0, delta, finish_reason: finishReason }],
  };
}

function summarizeToolInput(input) {
  if (!input || typeof input !== "object") return "";
  const parts = [];
  // Bash
  if (typeof input.command === "string") parts.push(input.command);
  // Read / Edit / Write
  if (typeof input.filePath === "string") parts.push(input.filePath);
  // Glob
  if (typeof input.pattern === "string") parts.push(input.pattern);
  // Grep
  if (typeof input.regex === "string") parts.push(input.regex);
  // Description (Bash, Task)
  if (typeof input.description === "string") parts.push(input.description);
  // Task / subagent
  if (typeof input.prompt === "string") parts.push(input.prompt.slice(0, 120));
  if (typeof input.subagent_type === "string") parts.push(`type=${input.subagent_type}`);
  return parts.filter(Boolean).join(" — ");
}

function formatStatusLine(label, detail = "") {
  return detail ? `[${label}] ${detail}\n` : `[${label}]\n`;
}

/**
 * Process a parsed stream-json event, emitting OpenAI chunks via `send`.
 * Returns true if the event produced visible content (text/thinking/tool).
 */
function processStreamEvent(event, ctx) {
  const { completionId, created, model, send, seenToolUseIds, seenTaskIds, seenToolResults } = ctx;

  if (event.type === "stream_event" && event.event?.type === "content_block_delta") {
    if (event.event.delta?.type === "text_delta" && event.event.delta.text) {
      ctx.textChunkCount += 1;
      ctx.textCharCount += event.event.delta.text.length;
      send(createOpenAIChunk(completionId, created, model, { content: event.event.delta.text }));
      return true;
    }
    if (event.event.delta?.type === "thinking_delta" && event.event.delta.thinking) {
      send(createOpenAIChunk(completionId, created, model, { reasoning_content: event.event.delta.thinking }));
      return true;
    }
  } else if (event.type === "stream_event" && event.event?.type === "message_delta") {
    if (event.event.delta?.stop_reason && !ctx.finishSent) {
      ctx.finishSent = true;
      send(createOpenAIChunk(completionId, created, model, {}, "stop"));
    }
  } else if (event.type === "assistant" && Array.isArray(event.message?.content)) {
    for (const block of event.message.content) {
      if (block?.type === "tool_use" && block.id && !seenToolUseIds.has(block.id)) {
        seenToolUseIds.set(block.id, block.name || "unknown");
        send(createOpenAIChunk(completionId, created, model, {
          content: formatStatusLine(`Tool: ${block.name || "unknown"}`, summarizeToolInput(block.input)),
        }));
      }
    }
  } else if (event.type === "system" && event.subtype === "task_started" && event.task_id && !seenTaskIds.has(`start:${event.task_id}`)) {
    seenTaskIds.add(`start:${event.task_id}`);
    send(createOpenAIChunk(completionId, created, model, {
      content: formatStatusLine("Subagent started", event.description || event.prompt || event.task_id),
    }));
  } else if (event.type === "system" && event.subtype === "task_notification" && event.task_id && !seenTaskIds.has(`done:${event.task_id}`)) {
    seenTaskIds.add(`done:${event.task_id}`);
    send(createOpenAIChunk(completionId, created, model, {
      content: formatStatusLine("Subagent completed", event.summary || event.task_id),
    }));
  } else if (event.type === "user" && event.uuid && event.tool_use_result && !seenToolResults.has(event.uuid)) {
    seenToolResults.add(event.uuid);
    const toolResult = event.tool_use_result;
    // Correlate tool name via tool_use_id from the message content
    const toolUseId = event.message?.content?.[0]?.tool_use_id;
    const toolName = (toolUseId && seenToolUseIds.get(toolUseId)) || "unknown";
    const isError = toolResult.is_error === true || event.message?.content?.[0]?.is_error === true;
    const preview = Array.isArray(toolResult.content)
      ? toolResult.content.map((item) => item?.text).filter(Boolean).join(" ")
      : (toolResult.stdout || "");
    if (preview) {
      const label = isError ? `Tool error: ${toolName}` : `Tool result: ${toolName}`;
      send(createOpenAIChunk(completionId, created, model, {
        content: formatStatusLine(label, preview.slice(0, 500)),
      }));
    }
  }

  return false;
}

/**
 * Attempt to stream with a specific account. Buffers initial events to detect
 * rate limiting before committing to the stream. Returns "rate_limited" if the
 * account is rate-limited, otherwise streams to completion and returns "done".
 */
function tryStreamWithAccount(controller, encoder, completionId, created, body, directory, account) {
  return new Promise((resolve) => {
    const childEnv = buildChildEnvWithToken(account.token);
    const child = spawn("claude", buildClaudeArgs(body, body.systemPrompt, true), {
      cwd: directory,
      env: childEnv,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let buffer = "";
    let closed = false;
    let stderrText = "";
    let probePhase = true; // buffer events until we know it's not rate-limited
    let rateLimitBailed = false; // true if we resolved "rate_limited" — don't touch controller
    const bufferedEvents = [];

    const ctx = {
      completionId,
      created,
      model: body.model,
      textChunkCount: 0,
      textCharCount: 0,
      finishSent: false,
      seenToolUseIds: new Map(),  // id → tool name, for correlating results
      seenTaskIds: new Set(),
      seenToolResults: new Set(),
      send(payload) {
        if (closed) return;
        try {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(payload)}\n\n`));
        } catch {
          closed = true;
        }
      },
    };

    const closeStream = () => {
      if (closed) return;
      closed = true;
      try {
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      } catch {
        // already closed
      }
      try {
        controller.close();
      } catch {
        // already closed by runtime
      }
    };

    /** Flush buffered events and exit probe phase. */
    const commitToStream = () => {
      probePhase = false;
      for (const evt of bufferedEvents) {
        processStreamEvent(evt, ctx);
      }
      bufferedEvents.length = 0;
    };

    child.stdout.on("data", (chunk) => {
      buffer += chunk.toString("utf-8");
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const event = JSON.parse(line);

          // During probe phase, check for rate limiting before sending anything
          if (probePhase) {
            const rl = detectRateLimitStream(event);
            if (rl.rateLimited) {
              markAccountRateLimited(account.email, rl.resetsAt);
              rateLimitBailed = true;
              child.kill("SIGTERM");
              resolve("rate_limited");
              return;
            }
            bufferedEvents.push(event);

            // If we see actual content, commit to this account
            if (
              (event.type === "stream_event" && event.event?.type === "content_block_start") ||
              (event.type === "stream_event" && event.event?.type === "content_block_delta") ||
              (event.type === "stream_event" && event.event?.type === "message_start" && event.event?.message?.usage)
            ) {
              commitToStream();
            }
            continue;
          }

          processStreamEvent(event, ctx);
        } catch {
          // ignore malformed line fragments
        }
      }
    });

    child.stderr.on("data", (chunk) => {
      if (stderrText.length < 4000) {
        stderrText += chunk.toString("utf-8");
      }
    });

    child.on("close", (exitCode) => {
      // If we bailed due to rate limiting, the controller belongs to the next
      // account attempt — do NOT write to it or close it.
      if (rateLimitBailed) {
        console.error(
          `[aidevops] Claude proxy: killed rate-limited child account=${account.email} exitCode=${exitCode}`,
        );
        return;
      }

      // If we never exited probe phase (e.g. very short response), flush now
      if (probePhase) {
        commitToStream();
      }

      if (exitCode !== 0 && stderrText.trim()) {
        ctx.send(createOpenAIChunk(completionId, created, body.model, {
          content: `\n[Claude CLI transport error: ${stderrText.trim().slice(0, 500)}]`,
        }));
      }
      if (!ctx.finishSent) {
        ctx.finishSent = true;
        ctx.send(createOpenAIChunk(completionId, created, body.model, {}, "stop"));
      }
      console.error(
        `[aidevops] Claude proxy: stream complete model=${body.model} account=${account.email} exitCode=${exitCode} textChunks=${ctx.textChunkCount} textChars=${ctx.textCharCount} stderr=${JSON.stringify(stderrText.trim().slice(0, 300))}`,
      );
      closeStream();
      resolve("done");
    });

    child.on("error", (err) => {
      if (probePhase) {
        resolve("error");
        return;
      }
      controller.error(err);
      resolve("done");
    });
  });
}

function streamClaudeResponse(body, directory) {
  const completionId = `chatcmpl-${crypto.randomUUID().replace(/-/g, "").slice(0, 28)}`;
  const created = Math.floor(Date.now() / 1000);
  const encoder = new TextEncoder();

  return new ReadableStream({
    async start(controller) {
      const accounts = await getAvailableAccounts();
      if (accounts.length === 0) {
        const errChunk = createOpenAIChunk(completionId, created, body.model, {
          content: "[Claude CLI transport: all Anthropic OAuth pool accounts are rate-limited]",
        });
        try {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(errChunk)}\n\n`));
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(createOpenAIChunk(completionId, created, body.model, {}, "stop"))}\n\n`));
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
        } catch {
          // already closed
        }
        return;
      }

      for (const account of accounts) {
        console.error(`[aidevops] Claude proxy: trying account ${account.email} (stream mode)`);
        const result = await tryStreamWithAccount(controller, encoder, completionId, created, body, directory, account);
        if (result === "rate_limited") {
          console.error(`[aidevops] Claude proxy: account ${account.email} rate-limited, trying next...`);
          continue;
        }
        return; // stream completed
      }

      // All accounts exhausted
      const errChunk = createOpenAIChunk(completionId, created, body.model, {
        content: "[Claude CLI transport: all Anthropic OAuth pool accounts are rate-limited]",
      });
      try {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(errChunk)}\n\n`));
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(createOpenAIChunk(completionId, created, body.model, {}, "stop"))}\n\n`));
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      } catch {
        // already closed
      }
    },
  });
}

function buildOpenAIResponse(body, content, usage) {
  return {
    id: `chatcmpl-${crypto.randomUUID().replace(/-/g, "").slice(0, 28)}`,
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model: body.model,
    choices: [
      {
        index: 0,
        message: { role: "assistant", content },
        finish_reason: "stop",
      },
    ],
    usage: {
      prompt_tokens: usage.input_tokens || 0,
      completion_tokens: usage.output_tokens || 0,
      total_tokens: (usage.input_tokens || 0) + (usage.output_tokens || 0),
    },
  };
}

async function handleChatCompletions(req, directory) {
  const incoming = await req.json();
  const parsed = parseChatMessages(incoming.messages || []);

  // Agent selection: X-Agent header > model name suffix (e.g. "claudecli/seo/opus") > default
  let agentName = req.headers.get("x-agent") || null;
  if (!agentName && typeof incoming.model === "string" && incoming.model.includes("/")) {
    const parts = incoming.model.split("/");
    if (parts.length >= 2 && AGENT_FILES[parts[1]]) {
      agentName = parts[1];
    }
  }

  const body = {
    model: incoming.model,
    agentName: agentName || "build-plus",
    systemPrompt: parsed.systemPrompt,
    prompt: parsed.prompt,
    stream: incoming.stream !== false,
  };

  console.error(
    `[aidevops] Claude proxy: request model=${body.model} agent=${body.agentName} stream=${body.stream} systemChars=${body.systemPrompt.length} promptChars=${body.prompt.length}`,
  );
  try {
    writeFileSync(
      "/tmp/claude-proxy-last-request.json",
      JSON.stringify({ model: body.model, agent: body.agentName, stream: body.stream, systemPrompt: body.systemPrompt, prompt: body.prompt }, null, 2),
      "utf-8",
    );
  } catch {
    // best effort debugging
  }

  if (incoming.stream === false) {
    const result = await runClaudeJson(body, directory);
    return new Response(JSON.stringify(buildOpenAIResponse(body, result.content, result.usage)), {
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(streamClaudeResponse(body, directory), {
    headers: SSE_HEADERS,
  });
}

export async function startClaudeProxy(client, directory) {
  if (typeof globalThis.Bun === "undefined") {
    console.error("[aidevops] Claude proxy: skipped (not running under Bun)");
    return null;
  }
  if (!isClaudeCliAvailable()) return null;
  if (proxyStarting) return null;
  if (proxyPort) return { port: proxyPort, models: getClaudeProxyModels() };

  proxyStarting = true;
  try {
    proxyServer = Bun.serve({
      port: CLAUDE_PROXY_DEFAULT_PORT,
      hostname: "127.0.0.1",
      idleTimeout: 120,
      async fetch(req) {
        const url = new URL(req.url);
        if (req.method === "GET" && url.pathname === "/v1/models") {
          return new Response(JSON.stringify({
            object: "list",
            data: getClaudeProxyModels().map((model) => ({ id: model.id, object: "model", owned_by: "claude-cli" })),
          }), {
            headers: { "Content-Type": "application/json" },
          });
        }

        if (req.method === "POST" && url.pathname === "/v1/chat/completions") {
          try {
            return await handleChatCompletions(req, directory);
          } catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            return new Response(JSON.stringify({
              error: { message, type: "server_error", code: "internal_error" },
            }), {
              status: 500,
              headers: { "Content-Type": "application/json" },
            });
          }
        }

        return new Response("Not Found", { status: 404 });
      },
    });

    proxyPort = proxyServer.port;
    const models = getClaudeProxyModels();

    try {
      await client.auth.set({
        path: { id: CLAUDE_PROVIDER_ID },
        body: { type: "api", key: "claude-cli-proxy" },
      });
    } catch {
      // best effort
    }

    persistClaudeProvider(proxyPort, models);
    console.error(`[aidevops] Claude proxy: started on port ${proxyPort}`);
    return { port: proxyPort, models };
  } catch (err) {
    console.error(`[aidevops] Claude proxy: failed to start: ${err.message}`);
    return null;
  } finally {
    proxyStarting = false;
  }
}

export function getClaudeProxyPort() {
  return proxyPort;
}
