/**
 * Bridge streaming and response collection for cursor/proxy.js.
 * Extracted to keep per-file complexity below the threshold.
 */

import { create, fromBinary, toBinary } from "@bufbuild/protobuf";
import {
  AgentClientMessageSchema, AgentServerMessageSchema, ExecClientMessageSchema,
  McpResultSchema, McpSuccessSchema, McpErrorSchema, McpTextContentSchema, McpToolResultContentItemSchema,
  ConversationStateStructureSchema,
} from "./proto/agent_pb.js";
import { frameConnectMessage } from "./proxy-bridge.js";
import { processServerMessage } from "./proxy-handlers.js";
import { createConnectFrameParser, makeHeartbeatBytes, parseConnectEndStream } from "./proxy-messages.js";
import { createThinkingTagFilter, createSSESenders, flushTagFilterToSSE, SSE_HEADERS } from "./proxy-sse.js";

/** Merge blobStore entries into stored conversation state. */
export function mergeBlobStoreIntoState(bridgeKey, blobStore, conversationStates) {
  const stored = conversationStates.get(bridgeKey);
  if (stored) {
    for (const [k, v] of blobStore) stored.blobStore.set(k, v);
    stored.lastAccessMs = Date.now();
  }
}

/** Spawn a bridge, send initial request frame, and start heartbeat. */
export function startBridge(accessToken, requestBytes, spawnBridgeFn) {
  const bridge = spawnBridgeFn({ accessToken, rpcPath: "/agent.v1.AgentService/Run" });
  bridge.write(frameConnectMessage(requestBytes));
  const heartbeatTimer = setInterval(() => bridge.write(makeHeartbeatBytes()), 5_000);
  return { bridge, heartbeatTimer };
}

/**
 * Create an SSE streaming Response that reads from a live bridge.
 * @param {{ bridge, heartbeatTimer, blobStore, mcpTools }} bridgeCtx
 * @param {string} modelId
 * @param {string} bridgeKey
 * @param {{ conversationStates: Map, activeBridges: Map }} proxyState
 */
export function createBridgeStreamResponse(bridgeCtx, modelId, bridgeKey, proxyState) {
  const { bridge, heartbeatTimer, blobStore, mcpTools } = bridgeCtx;
  const completionId = `chatcmpl-${crypto.randomUUID().replace(/-/g, "").slice(0, 28)}`;
  const created = Math.floor(Date.now() / 1000);
  const stream = new ReadableStream({
    start(controller) {
      const { sendSSE, sendDone, closeController, makeChunk } = createSSESenders(controller, completionId, created, modelId);
      const state = { toolCallIndex: 0, pendingExecs: [] };
      const tagFilter = createThinkingTagFilter();
      let mcpExecReceived = false;
      const processChunk = createConnectFrameParser((messageBytes) => {
        try {
          const serverMessage = fromBinary(AgentServerMessageSchema, messageBytes);
          processServerMessage(serverMessage, { blobStore, mcpTools, sendFrame: (data) => bridge.write(data) }, {
            onText(text, isThinking) {
              if (isThinking) { sendSSE(makeChunk({ reasoning_content: text })); return; }
              const { content, reasoning } = tagFilter.process(text);
              if (reasoning) sendSSE(makeChunk({ reasoning_content: reasoning }));
              if (content) sendSSE(makeChunk({ content }));
            },
            onMcpExec(exec) {
              state.pendingExecs.push(exec);
              mcpExecReceived = true;
              flushTagFilterToSSE(tagFilter, makeChunk, sendSSE);
              const toolCallIndex = state.toolCallIndex++;
              sendSSE(makeChunk({ tool_calls: [{ index: toolCallIndex, id: exec.toolCallId, type: "function", function: { name: exec.toolName, arguments: exec.decodedArgs } }] }));
              proxyState.activeBridges.set(bridgeKey, { bridge, heartbeatTimer, blobStore, mcpTools, pendingExecs: state.pendingExecs });
              sendSSE(makeChunk({}, "tool_calls"));
              sendDone();
              closeController();
            },
            onCheckpoint(checkpointBytes) {
              const stored = proxyState.conversationStates.get(bridgeKey);
              if (stored) { stored.checkpoint = checkpointBytes; stored.lastAccessMs = Date.now(); }
            },
          });
        } catch { /* Skip unparseable messages */ }
      }, (endStreamBytes) => {
        const endError = parseConnectEndStream(endStreamBytes);
        if (endError) sendSSE(makeChunk({ content: `\n[Error: ${endError.message}]` }));
      });
      bridge.onData(processChunk);
      bridge.onClose((code) => {
        clearInterval(heartbeatTimer);
        mergeBlobStoreIntoState(bridgeKey, blobStore, proxyState.conversationStates);
        if (!mcpExecReceived) {
          flushTagFilterToSSE(tagFilter, makeChunk, sendSSE);
          sendSSE(makeChunk({}, "stop"));
          sendDone();
          closeController();
        } else if (code !== 0) {
          sendSSE(makeChunk({ content: "\n[Error: bridge connection lost]" }));
          sendSSE(makeChunk({}, "stop"));
          sendDone();
          closeController();
          proxyState.activeBridges.delete(bridgeKey);
        }
      });
    },
  });
  return new Response(stream, { headers: SSE_HEADERS });
}

/** Resume a paused bridge by sending MCP results and continuing to stream. */
export function handleToolResultResume(active, toolResults, modelId, bridgeKey, proxyState) {
  const { bridge, heartbeatTimer, blobStore, mcpTools, pendingExecs } = active;
  for (const exec of pendingExecs) {
    const result = toolResults.find((r) => r.toolCallId === exec.toolCallId);
    const mcpResult = result
      ? create(McpResultSchema, { result: { case: "success", value: create(McpSuccessSchema, {
          content: [create(McpToolResultContentItemSchema, { content: { case: "text", value: create(McpTextContentSchema, { text: result.content }) } })],
          isError: false,
        })}})
      : create(McpResultSchema, { result: { case: "error", value: create(McpErrorSchema, { error: "Tool result not provided" }) }});
    const execClientMessage = create(ExecClientMessageSchema, {
      id: exec.execMsgId, execId: exec.execId,
      message: { case: "mcpResult", value: mcpResult },
    });
    const clientMessage = create(AgentClientMessageSchema, { message: { case: "execClientMessage", value: execClientMessage } });
    bridge.write(frameConnectMessage(toBinary(AgentClientMessageSchema, clientMessage)));
  }
  return createBridgeStreamResponse({ bridge, heartbeatTimer, blobStore, mcpTools }, modelId, bridgeKey, proxyState);
}

/** Handle a tool call exec during non-streaming response collection. */
export function handleNonStreamToolCall(exec, bridgeCtx, collectCtx) {
  const { bridge, heartbeatTimer, payload, bridgeKey, proxyState } = bridgeCtx;
  const { state, tagFilter, fullTextRef, resolve } = collectCtx;
  state.pendingExecs.push(exec);
  const flushed = tagFilter.flush();
  fullTextRef.value += flushed.content;
  state.toolCallIndex++;
  const toolCalls = [{ id: exec.toolCallId, type: "function", function: { name: exec.toolName, arguments: exec.decodedArgs } }];
  proxyState.activeBridges.set(bridgeKey, {
    bridge, heartbeatTimer, blobStore: payload.blobStore, mcpTools: payload.mcpTools, pendingExecs: state.pendingExecs,
  });
  resolve({ text: fullTextRef.value, toolCalls });
}

/** Collect a full (non-streaming) response from the bridge. */
export async function collectFullResponse(payload, accessToken, bridgeKey, proxyState, spawnBridgeFn) {
  const { promise, resolve } = Promise.withResolvers();
  const fullTextRef = { value: "" };
  let resolved = false;
  const { bridge, heartbeatTimer } = startBridge(accessToken, payload.requestBytes, spawnBridgeFn);
  const state = { toolCallIndex: 0, pendingExecs: [] };
  const tagFilter = createThinkingTagFilter();
  bridge.onData(createConnectFrameParser((messageBytes) => {
    try {
      const serverMessage = fromBinary(AgentServerMessageSchema, messageBytes);
      processServerMessage(serverMessage, { blobStore: payload.blobStore, mcpTools: payload.mcpTools, sendFrame: (data) => bridge.write(data) }, {
        onText(text, isThinking) {
          if (isThinking) return;
          const { content } = tagFilter.process(text);
          fullTextRef.value += content;
        },
        onMcpExec(exec) {
          if (resolved) return;
          resolved = true;
          handleNonStreamToolCall(exec, { bridge, heartbeatTimer, payload, bridgeKey, proxyState }, { state, tagFilter, fullTextRef, resolve });
        },
        onCheckpoint(checkpointBytes) {
          const stored = proxyState.conversationStates.get(bridgeKey);
          if (stored) { stored.checkpoint = checkpointBytes; stored.lastAccessMs = Date.now(); }
        },
      });
    } catch { /* Skip */ }
  }, () => { }));
  bridge.onClose(() => {
    clearInterval(heartbeatTimer);
    mergeBlobStoreIntoState(bridgeKey, payload.blobStore, proxyState.conversationStates);
    if (!resolved) {
      resolved = true;
      const flushed = tagFilter.flush();
      fullTextRef.value += flushed.content;
      resolve({ text: fullTextRef.value, toolCalls: null });
    }
  });
  return promise;
}
