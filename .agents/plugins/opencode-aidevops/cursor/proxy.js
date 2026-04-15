/**
 * Local OpenAI-compatible proxy that translates requests to Cursor's gRPC protocol.
 *
 * Implementation is split across sibling files for complexity management:
 *   proxy-bridge.js   — bridge spawn, frame encoding, tool alias resolution
 *   proxy-messages.js — protobuf message building, request parsing, frame parsing
 *   proxy-handlers.js — server message dispatching, exec rejection
 *   proxy-sse.js      — thinking-tag filter, SSE sender helpers
 *   proxy-stream.js   — bridge streaming, response collection
 */
import { callCursorUnaryRpc, spawnBridge } from "./proxy-bridge.js";
import {
  buildCursorRequest, parseMessages, deriveBridgeKey, buildOpenAIModelList,
} from "./proxy-messages.js";
import {
  createBridgeStreamResponse, startBridge, handleToolResultResume, collectFullResponse,
} from "./proxy-stream.js";
import { jsonResponse, textResponse } from "../response-helpers.mjs";

export { callCursorUnaryRpc };

const CONVERSATION_TTL_MS = 30 * 60 * 1000;
const MAX_TOOL_ROUNDS = 25;

// Shared mutable state for session/bridge management.
const activeBridges = new Map();
const conversationStates = new Map();
const proxyState = { activeBridges, conversationStates };

let proxyServer;
let proxyPort;
let proxyAccessTokenProvider;
let proxyModels = [];

function evictStaleConversations() {
  const now = Date.now();
  for (const [key, stored] of conversationStates) {
    if (now - stored.lastAccessMs > CONVERSATION_TTL_MS) conversationStates.delete(key);
  }
}

function tryResumeBridge(bridgeKey, activeBridge, toolResults, modelId) {
  activeBridges.delete(bridgeKey);
  const resumeState = conversationStates.get(bridgeKey);
  if (resumeState) resumeState.toolRounds = (resumeState.toolRounds || 0) + 1;
  const loopGuardTripped = resumeState && resumeState.toolRounds >= MAX_TOOL_ROUNDS;
  if (loopGuardTripped) console.error(`[proxy] Tool loop guard: conversation ${bridgeKey} exceeded ${MAX_TOOL_ROUNDS} tool rounds on resume, killing bridge`);
  if (!loopGuardTripped && activeBridge.bridge.alive) {
    return handleToolResultResume(activeBridge, toolResults, modelId, bridgeKey, proxyState);
  }
  clearInterval(activeBridge.heartbeatTimer);
  activeBridge.bridge.end();
  return null;
}

function cleanupStaleBridge(bridgeKey, activeBridge) {
  if (activeBridge && activeBridges.has(bridgeKey)) {
    clearInterval(activeBridge.heartbeatTimer);
    activeBridge.bridge.end();
    activeBridges.delete(bridgeKey);
  }
}

function getOrCreateConversationState(bridgeKey) {
  let stored = conversationStates.get(bridgeKey);
  if (!stored) {
    stored = { conversationId: crypto.randomUUID(), checkpoint: null, blobStore: new Map(), lastAccessMs: Date.now(), toolRounds: 0 };
    conversationStates.set(bridgeKey, stored);
  }
  stored.lastAccessMs = Date.now();
  return stored;
}

function updateToolRoundCounter(stored, toolResults, userText, hadActiveBridge) {
  if (toolResults.length > 0 && !hadActiveBridge) {
    stored.toolRounds = (stored.toolRounds || 0) + 1;
  } else if (userText && toolResults.length === 0) {
    stored.toolRounds = 0;
  }
}

function handleChatCompletion(body, accessToken) {
  const { systemPrompt, userText, turns, toolResults } = parseMessages(body.messages);
  const modelId = body.model;
  const tools = body.tools ?? [];
  console.error(`[proxy] handleChatCompletion: model=${modelId}, tools=${tools.length}, userText=${(userText || '').slice(0, 80)}, toolResults=${toolResults.length}`);
  if (!userText && toolResults.length === 0) {
    return jsonResponse(
      { error: { message: "No user message found", type: "invalid_request_error" } },
      { status: 400 },
    );
  }
  const bridgeKey = deriveBridgeKey(modelId, body.messages);
  const activeBridge = activeBridges.get(bridgeKey);
  if (activeBridge && toolResults.length > 0) {
    const resumed = tryResumeBridge(bridgeKey, activeBridge, toolResults, modelId);
    if (resumed) return resumed;
  }
  cleanupStaleBridge(bridgeKey, activeBridge);
  const stored = getOrCreateConversationState(bridgeKey);
  evictStaleConversations();
  updateToolRoundCounter(stored, toolResults, userText, !!activeBridge);
  const toolsExhausted = (stored.toolRounds || 0) >= MAX_TOOL_ROUNDS;
  if (toolsExhausted) console.error(`[proxy] Tool loop guard: conversation ${bridgeKey} exceeded ${MAX_TOOL_ROUNDS} tool rounds, disabling tools`);
  const mcpTools = [];
  const effectiveUserText = userText || (toolResults.length > 0 ? toolResults.map((r) => r.content).join("\n") : "");
  const payload = buildCursorRequest(
    { modelId, systemPrompt, userText: effectiveUserText, turns },
    { conversationId: stored.conversationId, checkpoint: stored.checkpoint, blobStore: stored.blobStore }
  );
  payload.mcpTools = mcpTools;
  if (body.stream === false) return handleNonStreamingResponse(payload, accessToken, modelId, bridgeKey);
  return handleStreamingResponse(payload, accessToken, modelId, bridgeKey);
}

function handleStreamingResponse(payload, accessToken, modelId, bridgeKey) {
  const { bridge, heartbeatTimer } = startBridge(accessToken, payload.requestBytes, spawnBridge);
  return createBridgeStreamResponse({ bridge, heartbeatTimer, blobStore: payload.blobStore, mcpTools: payload.mcpTools }, modelId, bridgeKey, proxyState);
}

async function handleNonStreamingResponse(payload, accessToken, modelId, bridgeKey) {
  const completionId = `chatcmpl-${crypto.randomUUID().replace(/-/g, "").slice(0, 28)}`;
  const created = Math.floor(Date.now() / 1000);
  const result = await collectFullResponse(payload, accessToken, bridgeKey, proxyState, spawnBridge);
  const message = { role: "assistant", content: result.text || "" };
  let finishReason = "stop";
  if (result.toolCalls && result.toolCalls.length > 0) { message.tool_calls = result.toolCalls; finishReason = "tool_calls"; }
  return jsonResponse({
    id: completionId, object: "chat.completion", created, model: modelId,
    choices: [{ index: 0, message, finish_reason: finishReason }],
    usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
  });
}

async function handleChatCompletionsRequest(req) {
  try {
    const body = (await req.json());
    if (!proxyAccessTokenProvider) throw new Error("Cursor proxy access token provider not configured");
    const accessToken = await proxyAccessTokenProvider();
    return handleChatCompletion(body, accessToken);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return jsonResponse(
      { error: { message, type: "server_error", code: "internal_error" } },
      { status: 500 },
    );
  }
}

async function handleProxyFetch(req) {
  const url = new URL(req.url);
  if (req.method === "GET" && url.pathname === "/v1/models") {
    return jsonResponse({ object: "list", data: buildOpenAIModelList(proxyModels) });
  }
  if (req.method === "POST" && url.pathname === "/v1/chat/completions") return handleChatCompletionsRequest(req);
  return textResponse("Not Found", { status: 404 });
}

export function getProxyPort() { return proxyPort; }

export async function startProxy(getAccessToken, models = []) {
  proxyAccessTokenProvider = getAccessToken;
  proxyModels = models.map((model) => ({ id: model.id, name: model.name }));
  if (proxyServer && proxyPort) return proxyPort;
  conversationStates.clear();
  activeBridges.clear();
  proxyServer = Bun.serve({
    port: parseInt(process.env.CURSOR_PROXY_PORT || "32123", 10),
    idleTimeout: 255,
    fetch: handleProxyFetch,
  });
  proxyPort = proxyServer.port;
  if (!proxyPort) throw new Error("Failed to bind proxy to a port");
  return proxyPort;
}

export function stopProxy() {
  if (proxyServer) {
    proxyServer.stop();
    proxyServer = undefined;
    proxyPort = undefined;
    proxyAccessTokenProvider = undefined;
    proxyModels = [];
  }
  for (const active of activeBridges.values()) { clearInterval(active.heartbeatTimer); active.bridge.end(); }
  activeBridges.clear();
  conversationStates.clear();
}
