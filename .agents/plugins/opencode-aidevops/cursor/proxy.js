/**
 * Local OpenAI-compatible proxy that translates requests to Cursor's gRPC protocol.
 *
 * Accepts POST /v1/chat/completions in OpenAI format, translates to Cursor's
 * protobuf/HTTP2 Connect protocol, and streams back OpenAI-format SSE.
 *
 * Tool calling uses Cursor's native MCP tool protocol:
 * - OpenAI tool defs → McpToolDefinition in RequestContext
 * - Cursor toolCallStarted/Delta/Completed → OpenAI tool_calls SSE chunks
 * - mcpArgs exec → pause stream, return tool_calls to caller
 * - Follow-up request with tool results → resume bridge with mcpResult
 *
 * HTTP/2 transport is delegated to a Node child process (h2-bridge.mjs)
 * because Bun's node:http2 module is broken.
 */
import { create, fromBinary, fromJson, toBinary, toJson } from "@bufbuild/protobuf";
import { ValueSchema } from "@bufbuild/protobuf/wkt";
import { AgentClientMessageSchema, AgentRunRequestSchema, AgentServerMessageSchema, ClientHeartbeatSchema, ConversationActionSchema, ConversationStateStructureSchema, ConversationStepSchema, AgentConversationTurnStructureSchema, ConversationTurnStructureSchema, AssistantMessageSchema, BackgroundShellSpawnResultSchema, DeleteResultSchema, DeleteRejectedSchema, DiagnosticsResultSchema, ExecClientMessageSchema, FetchErrorSchema, FetchResultSchema, GetBlobResultSchema, GrepErrorSchema, GrepResultSchema, KvClientMessageSchema, LsRejectedSchema, LsResultSchema, McpErrorSchema, McpResultSchema, McpSuccessSchema, McpTextContentSchema, McpToolDefinitionSchema, McpToolResultContentItemSchema, ModelDetailsSchema, ReadRejectedSchema, ReadResultSchema, RequestContextResultSchema, RequestContextSchema, RequestContextSuccessSchema, SetBlobResultSchema, ShellRejectedSchema, ShellResultSchema, UserMessageActionSchema, UserMessageSchema, WriteRejectedSchema, WriteResultSchema, WriteShellStdinErrorSchema, WriteShellStdinResultSchema, } from "./proto/agent_pb.js";
import { createHash } from "node:crypto";
import { resolve as pathResolve } from "node:path";
const CURSOR_API_URL = process.env.CURSOR_API_URL ?? "https://api2.cursor.sh";
const CONNECT_END_STREAM_FLAG = 0b00000010;
const BRIDGE_PATH = pathResolve(import.meta.dir, "h2-bridge.mjs");
const SSE_HEADERS = {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
};
// Active bridges keyed by a session token (derived from conversation state).
// When tool_calls are returned, the bridge stays alive. The next request
// with tool results looks up the bridge and sends mcpResult messages.
const activeBridges = new Map();
const conversationStates = new Map();
const CONVERSATION_TTL_MS = 30 * 60 * 1000; // 30 minutes
// Tool name alias map (t1553) — Cursor models may use variant names for tools.
// Ported from Nomadcxx/opencode-cursor src/proxy/tool-loop.ts TOOL_NAME_ALIASES.
// Keys are lowercased; values are the canonical OpenCode tool names.
const TOOL_NAME_ALIASES = new Map([
    // bash aliases
    ["runcommand", "bash"], ["executecommand", "bash"], ["runterminalcommand", "bash"],
    ["terminalcommand", "bash"], ["shellcommand", "bash"], ["shell", "bash"],
    ["terminal", "bash"], ["bashcommand", "bash"], ["runbash", "bash"],
    ["executebash", "bash"],
    // read aliases
    ["readfile", "read"], ["getfile", "read"], ["filecontent", "read"],
    ["readfilecontent", "read"],
    // write aliases
    ["writefile", "write"], ["createfile", "write"], ["savefile", "write"],
    // edit aliases
    ["editfile", "edit"], ["modifyfile", "edit"], ["updatefile", "edit"],
    ["replaceinfile", "edit"],
    // grep aliases
    ["searchcontent", "grep"], ["searchcode", "grep"], ["findcontent", "grep"],
    ["grepfiles", "grep"], ["searchfiles", "grep"],
    // glob aliases
    ["findfiles", "glob"], ["globfiles", "glob"], ["fileglob", "glob"],
    ["matchfiles", "glob"],
    // ls aliases
    ["listdirectory", "ls"], ["listfiles", "ls"], ["listdir", "ls"],
    ["readdir", "ls"],
]);
/**
 * Resolve a tool name through the alias map.
 * Returns the canonical name if an alias matches, otherwise the original name.
 * @param {string} name - Tool name from Cursor's response
 * @returns {string} Resolved canonical tool name
 */
function resolveToolAlias(name) {
    if (!name) return name;
    const lower = name.toLowerCase().replace(/[_\-\s]/g, "");
    return TOOL_NAME_ALIASES.get(lower) || name;
}
function evictStaleConversations() {
    const now = Date.now();
    for (const [key, stored] of conversationStates) {
        if (now - stored.lastAccessMs > CONVERSATION_TTL_MS) {
            conversationStates.delete(key);
        }
    }
}
/** Length-prefix a message: [4-byte BE length][payload] */
function lpEncode(data) {
    const buf = Buffer.alloc(4 + data.length);
    buf.writeUInt32BE(data.length, 0);
    buf.set(data, 4);
    return buf;
}
/** Connect protocol frame: [1-byte flags][4-byte BE length][payload] */
function frameConnectMessage(data, flags = 0) {
    const frame = Buffer.alloc(5 + data.length);
    frame[0] = flags;
    frame.writeUInt32BE(data.length, 1);
    frame.set(data, 5);
    return frame;
}
function spawnBridge(options) {
    const proc = Bun.spawn(["node", BRIDGE_PATH], {
        stdin: "pipe",
        stdout: "pipe",
        stderr: "ignore",
    });
    const config = JSON.stringify({
        accessToken: options.accessToken,
        url: options.url ?? CURSOR_API_URL,
        path: options.rpcPath,
    });
    proc.stdin.write(lpEncode(new TextEncoder().encode(config)));
    const cbs = {
        data: null,
        close: null,
    };
    // Track exit state so late onClose registrations fire immediately.
    let exited = false;
    let exitCode = 1;
    (async () => {
        const reader = proc.stdout.getReader();
        let pending = Buffer.alloc(0);
        try {
            while (true) {
                const { done, value } = await reader.read();
                if (done)
                    break;
                pending = Buffer.concat([pending, Buffer.from(value)]);
                while (pending.length >= 4) {
                    const len = pending.readUInt32BE(0);
                    if (pending.length < 4 + len)
                        break;
                    const payload = pending.subarray(4, 4 + len);
                    pending = pending.subarray(4 + len);
                    cbs.data?.(Buffer.from(payload));
                }
            }
        }
        catch {
            // Stream ended
        }
        const code = await proc.exited ?? 1;
        exited = true;
        exitCode = code;
        cbs.close?.(code);
    })();
    return {
        proc,
        get alive() { return !exited; },
        write(data) {
            try {
                proc.stdin.write(lpEncode(data));
            }
            catch { }
        },
        end() {
            try {
                proc.stdin.write(lpEncode(new Uint8Array(0)));
                proc.stdin.end();
            }
            catch { }
        },
        onData(cb) { cbs.data = cb; },
        onClose(cb) {
            if (exited) {
                // Process already exited — invoke immediately so streams don't hang.
                queueMicrotask(() => cb(exitCode));
            }
            else {
                cbs.close = cb;
            }
        },
    };
}
export async function callCursorUnaryRpc(options) {
    const bridge = spawnBridge({
        accessToken: options.accessToken,
        rpcPath: options.rpcPath,
        url: options.url,
    });
    const chunks = [];
    const { promise, resolve } = Promise.withResolvers();
    let timedOut = false;
    const timeoutMs = options.timeoutMs ?? 5_000;
    const timeout = timeoutMs > 0
        ? setTimeout(() => {
            timedOut = true;
            try {
                bridge.proc.kill();
            }
            catch { }
        }, timeoutMs)
        : undefined;
    bridge.onData((chunk) => {
        chunks.push(Buffer.from(chunk));
    });
    bridge.onClose((exitCode) => {
        if (timeout)
            clearTimeout(timeout);
        resolve({
            body: Buffer.concat(chunks),
            exitCode,
            timedOut,
        });
    });
    bridge.write(frameConnectMessage(options.requestBody));
    bridge.end();
    return promise;
}
let proxyServer;
let proxyPort;
let proxyAccessTokenProvider;
let proxyModels = [];
function buildOpenAIModelList(models) {
    return models.map((model) => ({
        id: model.id,
        object: "model",
        created: 0,
        owned_by: "cursor",
    }));
}
export function getProxyPort() {
    return proxyPort;
}
export async function startProxy(getAccessToken, models = []) {
    proxyAccessTokenProvider = getAccessToken;
    proxyModels = models.map((model) => ({
        id: model.id,
        name: model.name,
    }));
    if (proxyServer && proxyPort)
        return proxyPort;
    proxyServer = Bun.serve({
        port: parseInt(process.env.CURSOR_PROXY_PORT || "32123", 10),
        idleTimeout: 255, // max — Cursor responses can take 30s+
        async fetch(req) {
            const url = new URL(req.url);
            if (req.method === "GET" && url.pathname === "/v1/models") {
                return new Response(JSON.stringify({
                    object: "list",
                    data: buildOpenAIModelList(proxyModels),
                }), { headers: { "Content-Type": "application/json" } });
            }
            if (req.method === "POST" && url.pathname === "/v1/chat/completions") {
                try {
                    const body = (await req.json());
                    if (!proxyAccessTokenProvider) {
                        throw new Error("Cursor proxy access token provider not configured");
                    }
                    const accessToken = await proxyAccessTokenProvider();
                    return handleChatCompletion(body, accessToken);
                }
                catch (err) {
                    const message = err instanceof Error ? err.message : String(err);
                    return new Response(JSON.stringify({
                        error: { message, type: "server_error", code: "internal_error" },
                    }), { status: 500, headers: { "Content-Type": "application/json" } });
                }
            }
            return new Response("Not Found", { status: 404 });
        },
    });
    proxyPort = proxyServer.port;
    if (!proxyPort)
        throw new Error("Failed to bind proxy to a port");
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
    // Clean up any lingering bridges
    for (const active of activeBridges.values()) {
        clearInterval(active.heartbeatTimer);
        active.bridge.end();
    }
    activeBridges.clear();
    conversationStates.clear();
}
function handleChatCompletion(body, accessToken) {
    const { systemPrompt, userText, turns, toolResults } = parseMessages(body.messages);
    const modelId = body.model;
    const tools = body.tools ?? [];
    if (!userText && toolResults.length === 0) {
        return new Response(JSON.stringify({
            error: {
                message: "No user message found",
                type: "invalid_request_error",
            },
        }), { status: 400, headers: { "Content-Type": "application/json" } });
    }
    // Check for an active bridge waiting for tool results
    const bridgeKey = deriveBridgeKey(modelId, body.messages);
    const activeBridge = activeBridges.get(bridgeKey);
    if (activeBridge && toolResults.length > 0) {
        activeBridges.delete(bridgeKey);
        if (activeBridge.bridge.alive) {
            // Resume the live bridge with tool results
            return handleToolResultResume(activeBridge, toolResults, modelId, bridgeKey);
        }
        // Bridge died (timeout, server disconnect, etc.).
        // Clean up and fall through to start a fresh bridge.
        clearInterval(activeBridge.heartbeatTimer);
        activeBridge.bridge.end();
    }
    // Clean up stale bridge if present
    if (activeBridge && activeBridges.has(bridgeKey)) {
        clearInterval(activeBridge.heartbeatTimer);
        activeBridge.bridge.end();
        activeBridges.delete(bridgeKey);
    }
    let stored = conversationStates.get(bridgeKey);
    if (!stored) {
        stored = {
            conversationId: crypto.randomUUID(),
            checkpoint: null,
            blobStore: new Map(),
            lastAccessMs: Date.now(),
        };
        conversationStates.set(bridgeKey, stored);
    }
    stored.lastAccessMs = Date.now();
    evictStaleConversations();
    // Build the request. Forward OpenAI tools to Cursor as MCP tools (t1553).
    // Cursor's gRPC protocol uses MCP tool definitions in the RequestContext.
    // When the model wants to use a tool, Cursor sends an mcpArgs exec message
    // which our proxy translates back to OpenAI tool_calls format. OpenCode
    // then executes the tool and sends the result back, which we forward to
    // Cursor as an mcpResult message. This enables the full tool loop:
    //   OpenCode → proxy → Cursor (mcpArgs) → proxy (tool_calls) → OpenCode
    //   OpenCode (tool result) → proxy (mcpResult) → Cursor → continues
    const mcpTools = tools.length > 0 ? buildMcpToolDefinitions(tools) : [];
    const effectiveUserText = userText || (toolResults.length > 0
        ? toolResults.map((r) => r.content).join("\n")
        : "");
    const payload = buildCursorRequest(modelId, systemPrompt, effectiveUserText, turns, stored.conversationId, stored.checkpoint, stored.blobStore);
    payload.mcpTools = mcpTools;
    if (body.stream === false) {
        return handleNonStreamingResponse(payload, accessToken, modelId, bridgeKey);
    }
    return handleStreamingResponse(payload, accessToken, modelId, bridgeKey);
}
/** Normalize OpenAI message content to a plain string. */
function textContent(content) {
    if (content == null)
        return "";
    if (typeof content === "string")
        return content;
    return content
        .filter((p) => p.type === "text" && p.text)
        .map((p) => p.text)
        .join("\n");
}
function parseMessages(messages) {
    let systemPrompt = "You are a helpful assistant.";
    const pairs = [];
    const toolResults = [];
    // Collect system messages
    const systemParts = messages
        .filter((m) => m.role === "system")
        .map((m) => textContent(m.content));
    if (systemParts.length > 0) {
        systemPrompt = systemParts.join("\n");
    }
    // Separate tool results from conversation turns
    const nonSystem = messages.filter((m) => m.role !== "system");
    let pendingUser = "";
    for (const msg of nonSystem) {
        if (msg.role === "tool") {
            toolResults.push({
                toolCallId: msg.tool_call_id ?? "",
                content: textContent(msg.content),
            });
        }
        else if (msg.role === "user") {
            if (pendingUser) {
                pairs.push({ userText: pendingUser, assistantText: "" });
            }
            pendingUser = textContent(msg.content);
        }
        else if (msg.role === "assistant") {
            // Skip assistant messages that are just tool_calls with no text
            const text = textContent(msg.content);
            if (pendingUser) {
                pairs.push({ userText: pendingUser, assistantText: text });
                pendingUser = "";
            }
        }
    }
    let lastUserText = "";
    if (pendingUser) {
        lastUserText = pendingUser;
    }
    else if (pairs.length > 0 && toolResults.length === 0) {
        const last = pairs.pop();
        lastUserText = last.userText;
    }
    return { systemPrompt, userText: lastUserText, turns: pairs, toolResults };
}
/** Convert OpenAI tool definitions to Cursor's MCP tool protobuf format. */
function buildMcpToolDefinitions(tools) {
    return tools.map((t) => {
        const fn = t.function;
        const jsonSchema = fn.parameters && typeof fn.parameters === "object"
            ? fn.parameters
            : { type: "object", properties: {}, required: [] };
        const inputSchema = toBinary(ValueSchema, fromJson(ValueSchema, jsonSchema));
        return create(McpToolDefinitionSchema, {
            name: fn.name,
            description: fn.description || "",
            providerIdentifier: "opencode",
            toolName: fn.name,
            inputSchema,
        });
    });
}
/** Decode a Cursor MCP arg value (protobuf Value bytes) to a JS value. */
function decodeMcpArgValue(value) {
    try {
        const parsed = fromBinary(ValueSchema, value);
        return toJson(ValueSchema, parsed);
    }
    catch { }
    return new TextDecoder().decode(value);
}
/** Decode a map of MCP arg values. */
function decodeMcpArgsMap(args) {
    const decoded = {};
    for (const [key, value] of Object.entries(args)) {
        decoded[key] = decodeMcpArgValue(value);
    }
    return decoded;
}
function buildCursorRequest(modelId, systemPrompt, userText, turns, conversationId, checkpoint, existingBlobStore) {
    const blobStore = new Map(existingBlobStore ?? []);
    // System prompt → blob store (Cursor requests it back via KV handshake)
    const systemJson = JSON.stringify({ role: "system", content: systemPrompt });
    const systemBytes = new TextEncoder().encode(systemJson);
    const systemBlobId = new Uint8Array(createHash("sha256").update(systemBytes).digest());
    blobStore.set(Buffer.from(systemBlobId).toString("hex"), systemBytes);
    let conversationState;
    if (checkpoint) {
        conversationState = fromBinary(ConversationStateStructureSchema, checkpoint);
    }
    else {
        const turnBytes = [];
        for (const turn of turns) {
            const userMsg = create(UserMessageSchema, {
                text: turn.userText,
                messageId: crypto.randomUUID(),
            });
            const userMsgBytes = toBinary(UserMessageSchema, userMsg);
            const stepBytes = [];
            if (turn.assistantText) {
                const step = create(ConversationStepSchema, {
                    message: {
                        case: "assistantMessage",
                        value: create(AssistantMessageSchema, { text: turn.assistantText }),
                    },
                });
                stepBytes.push(toBinary(ConversationStepSchema, step));
            }
            const agentTurn = create(AgentConversationTurnStructureSchema, {
                userMessage: userMsgBytes,
                steps: stepBytes,
            });
            const turnStructure = create(ConversationTurnStructureSchema, {
                turn: { case: "agentConversationTurn", value: agentTurn },
            });
            turnBytes.push(toBinary(ConversationTurnStructureSchema, turnStructure));
        }
        conversationState = create(ConversationStateStructureSchema, {
            rootPromptMessagesJson: [systemBlobId],
            turns: turnBytes,
            todos: [],
            pendingToolCalls: [],
            previousWorkspaceUris: [],
            fileStates: {},
            fileStatesV2: {},
            summaryArchives: [],
            turnTimings: [],
            subagentStates: {},
            selfSummaryCount: 0,
            readPaths: [],
        });
    }
    const userMessage = create(UserMessageSchema, {
        text: userText,
        messageId: crypto.randomUUID(),
    });
    const action = create(ConversationActionSchema, {
        action: {
            case: "userMessageAction",
            value: create(UserMessageActionSchema, { userMessage }),
        },
    });
    const modelDetails = create(ModelDetailsSchema, {
        modelId,
        displayModelId: modelId,
        displayName: modelId,
    });
    const runRequest = create(AgentRunRequestSchema, {
        conversationState,
        action,
        modelDetails,
        conversationId,
    });
    const clientMessage = create(AgentClientMessageSchema, {
        message: { case: "runRequest", value: runRequest },
    });
    return {
        requestBytes: toBinary(AgentClientMessageSchema, clientMessage),
        blobStore,
        mcpTools: [],
    };
}
function parseConnectEndStream(data) {
    try {
        const payload = JSON.parse(new TextDecoder().decode(data));
        const error = payload?.error;
        if (error) {
            const code = error.code ?? "unknown";
            const message = error.message ?? "Unknown error";
            return new Error(`Connect error ${code}: ${message}`);
        }
        return null;
    }
    catch {
        return new Error("Failed to parse Connect end stream");
    }
}
function makeHeartbeatBytes() {
    const heartbeat = create(AgentClientMessageSchema, {
        message: {
            case: "clientHeartbeat",
            value: create(ClientHeartbeatSchema, {}),
        },
    });
    return frameConnectMessage(toBinary(AgentClientMessageSchema, heartbeat));
}
/**
 * Create a stateful parser for Connect protocol frames.
 * Handles buffering partial data across chunks.
 */
function createConnectFrameParser(onMessage, onEndStream) {
    let pending = Buffer.alloc(0);
    return (incoming) => {
        pending = Buffer.concat([pending, incoming]);
        while (pending.length >= 5) {
            const flags = pending[0];
            const msgLen = pending.readUInt32BE(1);
            if (pending.length < 5 + msgLen)
                break;
            const messageBytes = pending.subarray(5, 5 + msgLen);
            pending = pending.subarray(5 + msgLen);
            if (flags & CONNECT_END_STREAM_FLAG) {
                onEndStream(messageBytes);
            }
            else {
                onMessage(messageBytes);
            }
        }
    };
}
const THINKING_TAG_NAMES = ['think', 'thinking', 'reasoning', 'thought', 'think_intent'];
const MAX_THINKING_TAG_LEN = 16; // </think_intent> is 15 chars
/**
 * Strip thinking tags from streamed text, routing tagged content to reasoning.
 * Buffers partial tags across chunk boundaries.
 */
function createThinkingTagFilter() {
    let buffer = '';
    let inThinking = false;
    return {
        process(text) {
            const input = buffer + text;
            buffer = '';
            let content = '';
            let reasoning = '';
            let lastIdx = 0;
            const re = new RegExp(`<(/?)(?:${THINKING_TAG_NAMES.join('|')})\\s*>`, 'gi');
            let match;
            while ((match = re.exec(input)) !== null) {
                const before = input.slice(lastIdx, match.index);
                if (inThinking)
                    reasoning += before;
                else
                    content += before;
                inThinking = match[1] !== '/';
                lastIdx = re.lastIndex;
            }
            const rest = input.slice(lastIdx);
            // Buffer a trailing '<' that could be the start of a thinking tag.
            const ltPos = rest.lastIndexOf('<');
            if (ltPos >= 0 && rest.length - ltPos < MAX_THINKING_TAG_LEN && /^<\/?[a-z_]*$/i.test(rest.slice(ltPos))) {
                buffer = rest.slice(ltPos);
                const before = rest.slice(0, ltPos);
                if (inThinking)
                    reasoning += before;
                else
                    content += before;
            }
            else {
                if (inThinking)
                    reasoning += rest;
                else
                    content += rest;
            }
            return { content, reasoning };
        },
        flush() {
            const b = buffer;
            buffer = '';
            if (!b)
                return { content: '', reasoning: '' };
            return inThinking ? { content: '', reasoning: b } : { content: b, reasoning: '' };
        },
    };
}
function processServerMessage(msg, blobStore, mcpTools, sendFrame, state, onText, onMcpExec, onCheckpoint) {
    const msgCase = msg.message.case;
    if (msgCase === "interactionUpdate") {
        handleInteractionUpdate(msg.message.value, onText);
    }
    else if (msgCase === "kvServerMessage") {
        handleKvMessage(msg.message.value, blobStore, sendFrame);
    }
    else if (msgCase === "execServerMessage") {
        handleExecMessage(msg.message.value, mcpTools, sendFrame, onMcpExec);
    }
    else if (msgCase === "conversationCheckpointUpdate" && onCheckpoint) {
        onCheckpoint(toBinary(ConversationStateStructureSchema, msg.message.value));
    }
}
function handleInteractionUpdate(update, onText) {
    const updateCase = update.message?.case;
    if (updateCase === "textDelta") {
        const delta = update.message.value.text || "";
        if (delta)
            onText(delta, false);
    }
    else if (updateCase === "thinkingDelta") {
        const delta = update.message.value.text || "";
        if (delta)
            onText(delta, true);
    }
    // toolCallStarted, partialToolCall, toolCallDelta, toolCallCompleted
    // are intentionally ignored. MCP tool calls flow through the exec
    // message path (mcpArgs → mcpResult), not interaction updates.
}
/** Send a KV client response back to Cursor. */
function sendKvResponse(kvMsg, messageCase, value, sendFrame) {
    const response = create(KvClientMessageSchema, {
        id: kvMsg.id,
        message: { case: messageCase, value: value },
    });
    const clientMsg = create(AgentClientMessageSchema, {
        message: { case: "kvClientMessage", value: response },
    });
    sendFrame(frameConnectMessage(toBinary(AgentClientMessageSchema, clientMsg)));
}
function handleKvMessage(kvMsg, blobStore, sendFrame) {
    const kvCase = kvMsg.message.case;
    if (kvCase === "getBlobArgs") {
        const blobId = kvMsg.message.value.blobId;
        const blobIdKey = Buffer.from(blobId).toString("hex");
        const blobData = blobStore.get(blobIdKey);
        sendKvResponse(kvMsg, "getBlobResult", create(GetBlobResultSchema, blobData ? { blobData } : {}), sendFrame);
    }
    else if (kvCase === "setBlobArgs") {
        const { blobId, blobData } = kvMsg.message.value;
        blobStore.set(Buffer.from(blobId).toString("hex"), blobData);
        sendKvResponse(kvMsg, "setBlobResult", create(SetBlobResultSchema, {}), sendFrame);
    }
}
function handleExecMessage(execMsg, mcpTools, sendFrame, onMcpExec) {
    const execCase = execMsg.message.case;
    if (execCase === "requestContextArgs") {
        const requestContext = create(RequestContextSchema, {
            rules: [],
            repositoryInfo: [],
            tools: mcpTools,
            gitRepos: [],
            projectLayouts: [],
            mcpInstructions: [],
            fileContents: {},
            customSubagents: [],
        });
        const result = create(RequestContextResultSchema, {
            result: {
                case: "success",
                value: create(RequestContextSuccessSchema, { requestContext }),
            },
        });
        sendExecResult(execMsg, "requestContextResult", result, sendFrame);
        return;
    }
    if (execCase === "mcpArgs") {
        const mcpArgs = execMsg.message.value;
        const decoded = decodeMcpArgsMap(mcpArgs.args ?? {});
        // Resolve tool name aliases (t1553) — Cursor models may use variant
        // names like "runcommand" instead of "bash". The alias map normalises
        // these back to the canonical OpenCode tool names that OpenCode's
        // ai-sdk layer expects in the tool_calls response.
        const rawToolName = mcpArgs.toolName || mcpArgs.name;
        const resolvedToolName = resolveToolAlias(rawToolName);
        onMcpExec({
            execId: execMsg.execId,
            execMsgId: execMsg.id,
            toolCallId: mcpArgs.toolCallId || crypto.randomUUID(),
            toolName: resolvedToolName,
            decodedArgs: JSON.stringify(decoded),
        });
        return;
    }
    // --- Reject native Cursor tools ---
    // The model tries these first. We must respond with rejection/error
    // so it falls back to our MCP tools (registered via RequestContext).
    const REJECT_REASON = "Tool not available in this environment. Use the MCP tools provided instead.";
    if (execCase === "readArgs") {
        const args = execMsg.message.value;
        const result = create(ReadResultSchema, {
            result: { case: "rejected", value: create(ReadRejectedSchema, { path: args.path, reason: REJECT_REASON }) },
        });
        sendExecResult(execMsg, "readResult", result, sendFrame);
        return;
    }
    if (execCase === "lsArgs") {
        const args = execMsg.message.value;
        const result = create(LsResultSchema, {
            result: { case: "rejected", value: create(LsRejectedSchema, { path: args.path, reason: REJECT_REASON }) },
        });
        sendExecResult(execMsg, "lsResult", result, sendFrame);
        return;
    }
    if (execCase === "grepArgs") {
        const result = create(GrepResultSchema, {
            result: { case: "error", value: create(GrepErrorSchema, { error: REJECT_REASON }) },
        });
        sendExecResult(execMsg, "grepResult", result, sendFrame);
        return;
    }
    if (execCase === "writeArgs") {
        const args = execMsg.message.value;
        const result = create(WriteResultSchema, {
            result: { case: "rejected", value: create(WriteRejectedSchema, { path: args.path, reason: REJECT_REASON }) },
        });
        sendExecResult(execMsg, "writeResult", result, sendFrame);
        return;
    }
    if (execCase === "deleteArgs") {
        const args = execMsg.message.value;
        const result = create(DeleteResultSchema, {
            result: { case: "rejected", value: create(DeleteRejectedSchema, { path: args.path, reason: REJECT_REASON }) },
        });
        sendExecResult(execMsg, "deleteResult", result, sendFrame);
        return;
    }
    if (execCase === "shellArgs" || execCase === "shellStreamArgs") {
        const args = execMsg.message.value;
        const result = create(ShellResultSchema, {
            result: {
                case: "rejected",
                value: create(ShellRejectedSchema, {
                    command: args.command ?? "",
                    workingDirectory: args.workingDirectory ?? "",
                    reason: REJECT_REASON,
                    isReadonly: false,
                }),
            },
        });
        sendExecResult(execMsg, "shellResult", result, sendFrame);
        return;
    }
    if (execCase === "backgroundShellSpawnArgs") {
        const args = execMsg.message.value;
        const result = create(BackgroundShellSpawnResultSchema, {
            result: {
                case: "rejected",
                value: create(ShellRejectedSchema, {
                    command: args.command ?? "",
                    workingDirectory: args.workingDirectory ?? "",
                    reason: REJECT_REASON,
                    isReadonly: false,
                }),
            },
        });
        sendExecResult(execMsg, "backgroundShellSpawnResult", result, sendFrame);
        return;
    }
    if (execCase === "writeShellStdinArgs") {
        const result = create(WriteShellStdinResultSchema, {
            result: { case: "error", value: create(WriteShellStdinErrorSchema, { error: REJECT_REASON }) },
        });
        sendExecResult(execMsg, "writeShellStdinResult", result, sendFrame);
        return;
    }
    if (execCase === "fetchArgs") {
        const args = execMsg.message.value;
        const result = create(FetchResultSchema, {
            result: { case: "error", value: create(FetchErrorSchema, { url: args.url ?? "", error: REJECT_REASON }) },
        });
        sendExecResult(execMsg, "fetchResult", result, sendFrame);
        return;
    }
    if (execCase === "diagnosticsArgs") {
        const result = create(DiagnosticsResultSchema, {});
        sendExecResult(execMsg, "diagnosticsResult", result, sendFrame);
        return;
    }
    // MCP resource/screen/computer exec types
    const miscCaseMap = {
        listMcpResourcesExecArgs: "listMcpResourcesExecResult",
        readMcpResourceExecArgs: "readMcpResourceExecResult",
        recordScreenArgs: "recordScreenResult",
        computerUseArgs: "computerUseResult",
    };
    const resultCase = miscCaseMap[execCase];
    if (resultCase) {
        sendExecResult(execMsg, resultCase, create(McpResultSchema, {}), sendFrame);
        return;
    }
    // Unknown exec type — log and ignore
    console.error(`[proxy] unhandled exec: ${execCase}`);
}
/** Send an exec client message back to Cursor. */
function sendExecResult(execMsg, messageCase, value, sendFrame) {
    const execClientMessage = create(ExecClientMessageSchema, {
        id: execMsg.id,
        execId: execMsg.execId,
        message: { case: messageCase, value: value },
    });
    const clientMessage = create(AgentClientMessageSchema, {
        message: { case: "execClientMessage", value: execClientMessage },
    });
    sendFrame(frameConnectMessage(toBinary(AgentClientMessageSchema, clientMessage)));
}
/** Derive a stable key to associate a bridge with a conversation. */
function deriveBridgeKey(modelId, messages) {
    // Stable key from model + first user message text.
    const firstUserMsg = messages.find((m) => m.role === "user");
    const firstUserText = firstUserMsg ? textContent(firstUserMsg.content) : "";
    return createHash("sha256")
        .update(`${modelId}:${firstUserText.slice(0, 200)}`)
        .digest("hex")
        .slice(0, 16);
}
/** Create an SSE streaming Response that reads from a live bridge. */
function createBridgeStreamResponse(bridge, heartbeatTimer, blobStore, mcpTools, modelId, bridgeKey) {
    const completionId = `chatcmpl-${crypto.randomUUID().replace(/-/g, "").slice(0, 28)}`;
    const created = Math.floor(Date.now() / 1000);
    const stream = new ReadableStream({
        start(controller) {
            const encoder = new TextEncoder();
            let closed = false;
            const sendSSE = (data) => {
                if (closed)
                    return;
                controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`));
            };
            const sendDone = () => {
                if (closed)
                    return;
                controller.enqueue(encoder.encode("data: [DONE]\n\n"));
            };
            const closeController = () => {
                if (closed)
                    return;
                closed = true;
                controller.close();
            };
            const makeChunk = (delta, finishReason = null) => ({
                id: completionId,
                object: "chat.completion.chunk",
                created,
                model: modelId,
                choices: [{ index: 0, delta, finish_reason: finishReason }],
            });
            const state = {
                toolCallIndex: 0,
                pendingExecs: [],
            };
            const tagFilter = createThinkingTagFilter();
            let mcpExecReceived = false;
            const processChunk = createConnectFrameParser((messageBytes) => {
                try {
                    const serverMessage = fromBinary(AgentServerMessageSchema, messageBytes);
                    processServerMessage(serverMessage, blobStore, mcpTools, (data) => bridge.write(data), state, (text, isThinking) => {
                        if (isThinking) {
                            sendSSE(makeChunk({ reasoning_content: text }));
                        }
                        else {
                            const { content, reasoning } = tagFilter.process(text);
                            if (reasoning)
                                sendSSE(makeChunk({ reasoning_content: reasoning }));
                            if (content)
                                sendSSE(makeChunk({ content }));
                        }
                    }, 
                    // onMcpExec — the model wants to execute a tool.
                    (exec) => {
                        state.pendingExecs.push(exec);
                        mcpExecReceived = true;
                        const flushed = tagFilter.flush();
                        if (flushed.reasoning)
                            sendSSE(makeChunk({ reasoning_content: flushed.reasoning }));
                        if (flushed.content)
                            sendSSE(makeChunk({ content: flushed.content }));
                        const toolCallIndex = state.toolCallIndex++;
                        sendSSE(makeChunk({
                            tool_calls: [{
                                    index: toolCallIndex,
                                    id: exec.toolCallId,
                                    type: "function",
                                    function: {
                                        name: exec.toolName,
                                        arguments: exec.decodedArgs,
                                    },
                                }],
                        }));
                        // Keep the bridge alive for tool result continuation.
                        activeBridges.set(bridgeKey, {
                            bridge,
                            heartbeatTimer,
                            blobStore,
                            mcpTools,
                            pendingExecs: state.pendingExecs,
                        });
                        sendSSE(makeChunk({}, "tool_calls"));
                        sendDone();
                        closeController();
                    }, (checkpointBytes) => {
                        const stored = conversationStates.get(bridgeKey);
                        if (stored) {
                            stored.checkpoint = checkpointBytes;
                            stored.lastAccessMs = Date.now();
                        }
                    });
                }
                catch {
                    // Skip unparseable messages
                }
            }, (endStreamBytes) => {
                const endError = parseConnectEndStream(endStreamBytes);
                if (endError) {
                    sendSSE(makeChunk({ content: `\n[Error: ${endError.message}]` }));
                }
            });
            bridge.onData(processChunk);
            bridge.onClose((code) => {
                clearInterval(heartbeatTimer);
                const stored = conversationStates.get(bridgeKey);
                if (stored) {
                    for (const [k, v] of blobStore)
                        stored.blobStore.set(k, v);
                    stored.lastAccessMs = Date.now();
                }
                if (!mcpExecReceived) {
                    const flushed = tagFilter.flush();
                    if (flushed.reasoning)
                        sendSSE(makeChunk({ reasoning_content: flushed.reasoning }));
                    if (flushed.content)
                        sendSSE(makeChunk({ content: flushed.content }));
                    sendSSE(makeChunk({}, "stop"));
                    sendDone();
                    closeController();
                }
                else if (code !== 0) {
                    // Bridge died while tool calls are pending (timeout, crash, etc.).
                    // Close the SSE stream so the client doesn't hang forever.
                    sendSSE(makeChunk({ content: "\n[Error: bridge connection lost]" }));
                    sendSSE(makeChunk({}, "stop"));
                    sendDone();
                    closeController();
                    // Remove stale entry so the next request doesn't try to resume it.
                    activeBridges.delete(bridgeKey);
                }
            });
        },
    });
    return new Response(stream, { headers: SSE_HEADERS });
}
/** Spawn a bridge, send the initial request frame, and start heartbeat. */
function startBridge(accessToken, requestBytes) {
    const bridge = spawnBridge({
        accessToken,
        rpcPath: "/agent.v1.AgentService/Run",
    });
    bridge.write(frameConnectMessage(requestBytes));
    const heartbeatTimer = setInterval(() => bridge.write(makeHeartbeatBytes()), 5_000);
    return { bridge, heartbeatTimer };
}
function handleStreamingResponse(payload, accessToken, modelId, bridgeKey) {
    const { bridge, heartbeatTimer } = startBridge(accessToken, payload.requestBytes);
    return createBridgeStreamResponse(bridge, heartbeatTimer, payload.blobStore, payload.mcpTools, modelId, bridgeKey);
}
/** Resume a paused bridge by sending MCP results and continuing to stream. */
function handleToolResultResume(active, toolResults, modelId, bridgeKey) {
    const { bridge, heartbeatTimer, blobStore, mcpTools, pendingExecs } = active;
    // Send mcpResult for each pending exec that has a matching tool result
    for (const exec of pendingExecs) {
        const result = toolResults.find((r) => r.toolCallId === exec.toolCallId);
        const mcpResult = result
            ? create(McpResultSchema, {
                result: {
                    case: "success",
                    value: create(McpSuccessSchema, {
                        content: [
                            create(McpToolResultContentItemSchema, {
                                content: {
                                    case: "text",
                                    value: create(McpTextContentSchema, { text: result.content }),
                                },
                            }),
                        ],
                        isError: false,
                    }),
                },
            })
            : create(McpResultSchema, {
                result: {
                    case: "error",
                    value: create(McpErrorSchema, { error: "Tool result not provided" }),
                },
            });
        const execClientMessage = create(ExecClientMessageSchema, {
            id: exec.execMsgId,
            execId: exec.execId,
            message: {
                case: "mcpResult",
                value: mcpResult,
            },
        });
        const clientMessage = create(AgentClientMessageSchema, {
            message: { case: "execClientMessage", value: execClientMessage },
        });
        bridge.write(frameConnectMessage(toBinary(AgentClientMessageSchema, clientMessage)));
    }
    return createBridgeStreamResponse(bridge, heartbeatTimer, blobStore, mcpTools, modelId, bridgeKey);
}
async function handleNonStreamingResponse(payload, accessToken, modelId, bridgeKey) {
    const completionId = `chatcmpl-${crypto.randomUUID().replace(/-/g, "").slice(0, 28)}`;
    const created = Math.floor(Date.now() / 1000);
    const result = await collectFullResponse(payload, accessToken, bridgeKey);
    const message = { role: "assistant", content: result.text || "" };
    let finishReason = "stop";
    if (result.toolCalls && result.toolCalls.length > 0) {
        message.tool_calls = result.toolCalls;
        finishReason = "tool_calls";
    }
    return new Response(JSON.stringify({
        id: completionId,
        object: "chat.completion",
        created,
        model: modelId,
        choices: [
            {
                index: 0,
                message,
                finish_reason: finishReason,
            },
        ],
        usage: {
            prompt_tokens: 0,
            completion_tokens: 0,
            total_tokens: 0,
        },
    }), { headers: { "Content-Type": "application/json" } });
}
async function collectFullResponse(payload, accessToken, bridgeKey) {
    const { promise, resolve } = Promise.withResolvers();
    let fullText = "";
    let resolved = false;
    const { bridge, heartbeatTimer } = startBridge(accessToken, payload.requestBytes);
    const state = {
        toolCallIndex: 0,
        pendingExecs: [],
    };
    const tagFilter = createThinkingTagFilter();
    bridge.onData(createConnectFrameParser((messageBytes) => {
        try {
            const serverMessage = fromBinary(AgentServerMessageSchema, messageBytes);
            processServerMessage(serverMessage, payload.blobStore, payload.mcpTools, (data) => bridge.write(data), state, (text, isThinking) => {
                if (isThinking)
                    return;
                const { content } = tagFilter.process(text);
                fullText += content;
            }, (exec) => {
                // Tool call received — resolve immediately with tool_calls
                // and keep the bridge alive for tool result continuation.
                if (resolved) return;
                resolved = true;
                state.pendingExecs.push(exec);
                const flushed = tagFilter.flush();
                fullText += flushed.content;
                const toolCallIndex = state.toolCallIndex++;
                const toolCalls = [{
                    id: exec.toolCallId,
                    type: "function",
                    function: {
                        name: exec.toolName,
                        arguments: exec.decodedArgs,
                    },
                }];
                // Keep the bridge alive for tool result continuation.
                activeBridges.set(bridgeKey, {
                    bridge,
                    heartbeatTimer,
                    blobStore: payload.blobStore,
                    mcpTools: payload.mcpTools,
                    pendingExecs: state.pendingExecs,
                });
                resolve({ text: fullText, toolCalls });
            }, (checkpointBytes) => {
                const stored = conversationStates.get(bridgeKey);
                if (stored) {
                    stored.checkpoint = checkpointBytes;
                    stored.lastAccessMs = Date.now();
                }
            });
        }
        catch {
            // Skip
        }
    }, () => { }));
    bridge.onClose(() => {
        clearInterval(heartbeatTimer);
        const stored = conversationStates.get(bridgeKey);
        if (stored) {
            for (const [k, v] of payload.blobStore)
                stored.blobStore.set(k, v);
            stored.lastAccessMs = Date.now();
        }
        if (!resolved) {
            resolved = true;
            const flushed = tagFilter.flush();
            fullText += flushed.content;
            resolve({ text: fullText, toolCalls: null });
        }
    });
    return promise;
}
