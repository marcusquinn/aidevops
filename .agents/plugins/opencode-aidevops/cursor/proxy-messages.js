/**
 * Message parsing, protobuf encoding, and request building for cursor/proxy.js.
 * Extracted to keep per-file complexity below the threshold.
 */

import { create, fromBinary, toBinary, toJson, fromJson } from "@bufbuild/protobuf";
import { ValueSchema } from "@bufbuild/protobuf/wkt";
import {
  AgentClientMessageSchema, AgentRunRequestSchema, AgentServerMessageSchema,
  ClientHeartbeatSchema, ConversationActionSchema, ConversationStateStructureSchema,
  ConversationStepSchema, AgentConversationTurnStructureSchema,
  ConversationTurnStructureSchema, AssistantMessageSchema,
  McpToolDefinitionSchema, ModelDetailsSchema,
  UserMessageActionSchema, UserMessageSchema,
} from "./proto/agent_pb.js";
import { createHash } from "node:crypto";
import { frameConnectMessage, CONNECT_END_STREAM_FLAG } from "./proxy-bridge.js";

export { AgentServerMessageSchema };

/** Normalize OpenAI message content to a plain string. */
export function textContent(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  return content.filter((p) => p.type === "text" && p.text).map((p) => p.text).join("\n");
}

/** Parse OpenAI messages array into system/turns/userText/toolResults. */
export function parseMessages(messages) {
  let systemPrompt = "You are a helpful assistant.";
  const pairs = [];
  const toolResults = [];
  const systemParts = messages.filter((m) => m.role === "system").map((m) => textContent(m.content));
  if (systemParts.length > 0) systemPrompt = systemParts.join("\n");
  const nonSystem = messages.filter((m) => m.role !== "system");
  let pendingUser = "";
  for (const msg of nonSystem) {
    if (msg.role === "tool") {
      toolResults.push({ toolCallId: msg.tool_call_id ?? "", content: textContent(msg.content) });
    } else if (msg.role === "user") {
      if (pendingUser) pairs.push({ userText: pendingUser, assistantText: "" });
      pendingUser = textContent(msg.content);
    } else if (msg.role === "assistant") {
      const text = textContent(msg.content);
      if (pendingUser) { pairs.push({ userText: pendingUser, assistantText: text }); pendingUser = ""; }
    }
  }
  let lastUserText = "";
  if (pendingUser) {
    lastUserText = pendingUser;
  } else if (pairs.length > 0 && toolResults.length === 0) {
    const last = pairs.pop();
    lastUserText = last.userText;
  }
  return { systemPrompt, userText: lastUserText, turns: pairs, toolResults };
}

/** Convert OpenAI tool definitions to Cursor's MCP tool protobuf format. */
export function buildMcpToolDefinitions(tools) {
  return tools.map((t) => {
    const fn = t.function;
    const jsonSchema = fn.parameters && typeof fn.parameters === "object"
      ? fn.parameters : { type: "object", properties: {}, required: [] };
    const inputSchema = toBinary(ValueSchema, fromJson(ValueSchema, jsonSchema));
    return create(McpToolDefinitionSchema, {
      name: fn.name, description: fn.description || "",
      providerIdentifier: "opencode", toolName: fn.name, inputSchema,
    });
  });
}

/** Decode a Cursor MCP arg value (protobuf Value bytes) to a JS value. */
export function decodeMcpArgValue(value) {
  try { const parsed = fromBinary(ValueSchema, value); return toJson(ValueSchema, parsed); } catch { }
  return new TextDecoder().decode(value);
}

/** Decode a map of MCP arg values. */
export function decodeMcpArgsMap(args) {
  const decoded = {};
  for (const [key, value] of Object.entries(args)) decoded[key] = decodeMcpArgValue(value);
  return decoded;
}

/** Encode a single conversation turn (user + optional assistant) to bytes. */
export function encodeTurn(turn) {
  const userMsg = create(UserMessageSchema, { text: turn.userText, messageId: crypto.randomUUID() });
  const userMsgBytes = toBinary(UserMessageSchema, userMsg);
  const stepBytes = [];
  if (turn.assistantText) {
    const step = create(ConversationStepSchema, {
      message: { case: "assistantMessage", value: create(AssistantMessageSchema, { text: turn.assistantText }) },
    });
    stepBytes.push(toBinary(ConversationStepSchema, step));
  }
  const agentTurn = create(AgentConversationTurnStructureSchema, { userMessage: userMsgBytes, steps: stepBytes });
  const turnStructure = create(ConversationTurnStructureSchema, {
    turn: { case: "agentConversationTurn", value: agentTurn },
  });
  return toBinary(ConversationTurnStructureSchema, turnStructure);
}

/** Build or restore a ConversationStateStructure. */
export function buildConversationState(turns, systemBlobId, checkpoint) {
  if (checkpoint) return fromBinary(ConversationStateStructureSchema, checkpoint);
  return create(ConversationStateStructureSchema, {
    rootPromptMessagesJson: [systemBlobId], turns: turns.map(encodeTurn),
    todos: [], pendingToolCalls: [], previousWorkspaceUris: [],
    fileStates: {}, fileStatesV2: {}, summaryArchives: [], turnTimings: [],
    subagentStates: {}, selfSummaryCount: 0, readPaths: [],
  });
}

/** Build a Cursor AgentRunRequest payload. */
export function buildCursorRequest(req, ctx) {
  const { modelId, systemPrompt, userText, turns } = req;
  const blobStore = new Map(ctx.blobStore ?? []);
  const systemJson = JSON.stringify({ role: "system", content: systemPrompt });
  const systemBytes = new TextEncoder().encode(systemJson);
  const systemBlobId = new Uint8Array(createHash("sha256").update(systemBytes).digest());
  blobStore.set(Buffer.from(systemBlobId).toString("hex"), systemBytes);
  const conversationState = buildConversationState(turns, systemBlobId, ctx.checkpoint);
  const userMessage = create(UserMessageSchema, { text: userText, messageId: crypto.randomUUID() });
  const action = create(ConversationActionSchema, {
    action: { case: "userMessageAction", value: create(UserMessageActionSchema, { userMessage }) },
  });
  const modelDetails = create(ModelDetailsSchema, { modelId, displayModelId: modelId, displayName: modelId });
  const runRequest = create(AgentRunRequestSchema, {
    conversationState, action, modelDetails, conversationId: ctx.conversationId,
  });
  const clientMessage = create(AgentClientMessageSchema, {
    message: { case: "runRequest", value: runRequest },
  });
  return { requestBytes: toBinary(AgentClientMessageSchema, clientMessage), blobStore, mcpTools: [] };
}

/** Derive a stable key to associate a bridge with a conversation. */
export function deriveBridgeKey(modelId, messages) {
  const firstUserMsg = messages.find((m) => m.role === "user");
  const firstUserText = firstUserMsg ? textContent(firstUserMsg.content) : "";
  return createHash("sha256")
    .update(`${modelId}:${firstUserText.slice(0, 200)}`)
    .digest("hex")
    .slice(0, 16);
}

/** Parse a Connect end-stream payload for errors. */
export function parseConnectEndStream(data) {
  try {
    const payload = JSON.parse(new TextDecoder().decode(data));
    const error = payload?.error;
    if (error) return new Error(`Connect error ${error.code ?? "unknown"}: ${error.message ?? "Unknown error"}`);
    return null;
  } catch {
    return new Error("Failed to parse Connect end stream");
  }
}

/** Build a ClientHeartbeat frame for keepalive. */
export function makeHeartbeatBytes() {
  const heartbeat = create(AgentClientMessageSchema, {
    message: { case: "clientHeartbeat", value: create(ClientHeartbeatSchema, {}) },
  });
  return frameConnectMessage(toBinary(AgentClientMessageSchema, heartbeat));
}

/**
 * Create a stateful parser for Connect protocol frames.
 * @param {Function} onMessage @param {Function} onEndStream
 */
export function createConnectFrameParser(onMessage, onEndStream) {
  let pending = Buffer.alloc(0);
  return (incoming) => {
    pending = Buffer.concat([pending, incoming]);
    while (pending.length >= 5) {
      const flags = pending[0];
      const msgLen = pending.readUInt32BE(1);
      if (pending.length < 5 + msgLen) break;
      const messageBytes = pending.subarray(5, 5 + msgLen);
      pending = pending.subarray(5 + msgLen);
      if (flags & CONNECT_END_STREAM_FLAG) onEndStream(messageBytes);
      else onMessage(messageBytes);
    }
  };
}

/** Build OpenAI model list from proxy models array. */
export function buildOpenAIModelList(models) {
  return models.map((model) => ({ id: model.id, object: "model", created: 0, owned_by: "cursor" }));
}
