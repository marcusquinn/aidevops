import { mkdirSync, readFileSync, writeFileSync } from "fs";
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

function sortAccountsByPriority(accounts) {
  return [...accounts].sort((a, b) => {
    const pa = Number(a?.priority || 0);
    const pb = Number(b?.priority || 0);
    if (pa !== pb) return pb - pa;
    return (a?.email || "").localeCompare(b?.email || "");
  });
}

async function getClaudeOAuthToken() {
  const accounts = sortAccountsByPriority(getAccounts("anthropic"));
  for (const account of accounts) {
    const token = await ensureValidToken("anthropic", account);
    if (token) {
      return token;
    }
  }
  return null;
}

async function buildClaudeChildEnv() {
  const token = await getClaudeOAuthToken();
  if (!token) {
    throw new Error("No valid Anthropic OAuth pool token available for Claude transport");
  }

  const childEnv = { ...process.env };
  delete childEnv.ANTHROPIC_API_KEY;
  childEnv.CLAUDE_CODE_OAUTH_TOKEN = token;
  return childEnv;
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
  const args = [
    "-p",
    "--model",
    body.model,
    "--permission-mode",
    "default",
    "--no-session-persistence",
  ];

  if (systemPrompt) {
    args.push("--append-system-prompt", systemPrompt);
  }

  if (streaming) {
    args.push("--verbose", "--output-format", "stream-json", "--include-partial-messages");
  } else {
    args.push("--output-format", "json");
  }

  args.push(body.prompt);
  return args;
}

async function runClaudeJson(body, directory) {
  const childEnv = await buildClaudeChildEnv();
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

  if (exitCode !== 0 || !stdout) {
    throw new Error(stderr || `claude exited with status ${exitCode}`);
  }

  const parsed = JSON.parse(stdout);
  return {
    content: parsed.result || "",
    usage: parsed.usage || {},
  };
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
  if (typeof input.command === "string") parts.push(input.command);
  if (typeof input.description === "string") parts.push(input.description);
  if (typeof input.prompt === "string") parts.push(input.prompt);
  if (typeof input.subagent_type === "string") parts.push(`type=${input.subagent_type}`);
  return parts.filter(Boolean).join(" — ");
}

function formatStatusLine(label, detail = "") {
  return detail ? `[${label}] ${detail}\n` : `[${label}]\n`;
}

function streamClaudeResponse(body, directory) {
  const completionId = `chatcmpl-${crypto.randomUUID().replace(/-/g, "").slice(0, 28)}`;
  const created = Math.floor(Date.now() / 1000);

  return new ReadableStream({
    async start(controller) {
      const encoder = new TextEncoder();
      const childEnv = await buildClaudeChildEnv();
      const child = spawn("claude", buildClaudeArgs(body, body.systemPrompt, true), {
        cwd: directory,
        env: childEnv,
        stdio: ["ignore", "pipe", "pipe"],
      });

      let buffer = "";
      let closed = false;
      let finishSent = false;
      let textChunkCount = 0;
      let textCharCount = 0;
      let stderrText = "";
      const seenToolUseIds = new Set();
      const seenTaskIds = new Set();
      const seenToolResults = new Set();

      const send = (payload) => {
        if (closed) return;
        try {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(payload)}\n\n`));
        } catch {
          closed = true;
        }
      };

      const close = () => {
        if (closed) return;
        closed = true;
        try {
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        } catch {
          return;
        }
        try {
          controller.close();
        } catch {
          // already closed by runtime
        }
      };

      child.stdout.on("data", (chunk) => {
        buffer += chunk.toString("utf-8");
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";

        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const event = JSON.parse(line);
            if (event.type === "stream_event" && event.event?.type === "content_block_delta") {
              if (event.event.delta?.type === "text_delta" && event.event.delta.text) {
                textChunkCount += 1;
                textCharCount += event.event.delta.text.length;
                send(createOpenAIChunk(completionId, created, body.model, { content: event.event.delta.text }));
              } else if (event.event.delta?.type === "thinking_delta" && event.event.delta.thinking) {
                send(createOpenAIChunk(completionId, created, body.model, { reasoning_content: event.event.delta.thinking }));
              }
            } else if (event.type === "stream_event" && event.event?.type === "message_delta") {
              if (event.event.delta?.stop_reason && !finishSent) {
                finishSent = true;
                send(createOpenAIChunk(completionId, created, body.model, {}, "stop"));
              }
            } else if (event.type === "assistant" && Array.isArray(event.message?.content)) {
              for (const block of event.message.content) {
                if (block?.type === "tool_use" && block.id && !seenToolUseIds.has(block.id)) {
                  seenToolUseIds.add(block.id);
                  send(createOpenAIChunk(completionId, created, body.model, {
                    content: formatStatusLine(`Tool: ${block.name || "unknown"}`, summarizeToolInput(block.input)),
                  }));
                }
              }
            } else if (event.type === "system" && event.subtype === "task_started" && event.task_id && !seenTaskIds.has(`start:${event.task_id}`)) {
              seenTaskIds.add(`start:${event.task_id}`);
              send(createOpenAIChunk(completionId, created, body.model, {
                content: formatStatusLine("Subagent started", event.description || event.prompt || event.task_id),
              }));
            } else if (event.type === "system" && event.subtype === "task_notification" && event.task_id && !seenTaskIds.has(`done:${event.task_id}`)) {
              seenTaskIds.add(`done:${event.task_id}`);
              send(createOpenAIChunk(completionId, created, body.model, {
                content: formatStatusLine("Subagent completed", event.summary || event.task_id),
              }));
            } else if (event.type === "user" && event.uuid && event.tool_use_result && !seenToolResults.has(event.uuid)) {
              seenToolResults.add(event.uuid);
              const toolResult = event.tool_use_result;
              const preview = Array.isArray(toolResult.content)
                ? toolResult.content.map((item) => item?.text).filter(Boolean).join(" ")
                : (toolResult.stdout || "");
              if (preview) {
                send(createOpenAIChunk(completionId, created, body.model, {
                  content: formatStatusLine("Tool result", preview.slice(0, 200)),
                }));
              }
            }
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
        if (exitCode !== 0 && stderrText.trim()) {
          send(createOpenAIChunk(completionId, created, body.model, {
            content: `\n[Claude CLI transport error: ${stderrText.trim().slice(0, 500)}]`,
          }));
        }
        if (!finishSent) {
          finishSent = true;
          send(createOpenAIChunk(completionId, created, body.model, {}, "stop"));
        }
        console.error(
          `[aidevops] Claude proxy: stream complete model=${body.model} exitCode=${exitCode} textChunks=${textChunkCount} textChars=${textCharCount} stderr=${JSON.stringify(stderrText.trim().slice(0, 300))}`,
        );
        close();
      });
      child.on("error", (err) => controller.error(err));
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
  const body = {
    model: incoming.model,
    systemPrompt: parsed.systemPrompt,
    prompt: parsed.prompt,
    stream: incoming.stream !== false,
  };

  console.error(
    `[aidevops] Claude proxy: request model=${body.model} stream=${body.stream} systemChars=${body.systemPrompt.length} promptChars=${body.prompt.length}`,
  );
  try {
    writeFileSync(
      "/tmp/claude-proxy-last-request.json",
      JSON.stringify({ model: body.model, stream: body.stream, systemPrompt: body.systemPrompt, prompt: body.prompt }, null, 2),
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
