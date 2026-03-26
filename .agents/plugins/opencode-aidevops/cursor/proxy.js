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
// Tool loop guard (t1553) — prevent infinite tool call loops.
// If a conversation exceeds this many tool call rounds, the proxy stops
// forwarding tools and lets the model generate a text-only response.
const MAX_TOOL_ROUNDS = 25;
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
/** Read length-prefixed frames from the bridge stdout and dispatch to callbacks. */
async function readBridgeOutput(proc, cbs) {
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
        await readBridgeOutput(proc, cbs);
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
    // Clear stale conversation states from previous sessions (t1553).
    // Stale checkpoints reference blobs that Cursor's server has evicted,
    // causing "Blob not found" errors on the first request.
    conversationStates.clear();
    activeBridges.clear();
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
/**
 * Try to resume an active bridge with tool results.
 * Returns a Response if the bridge was successfully resumed, or null if
 * the caller should fall through to start a fresh bridge.
 */
function tryResumeBridge(bridgeKey, activeBridge, toolResults, modelId) {
    activeBridges.delete(bridgeKey);
    // Tool loop guard (t1553): increment round counter for resume path.
    const resumeState = conversationStates.get(bridgeKey);
    if (resumeState) {
        resumeState.toolRounds = (resumeState.toolRounds || 0) + 1;
    }
    const loopGuardTripped = resumeState && resumeState.toolRounds >= MAX_TOOL_ROUNDS;
    if (loopGuardTripped) {
        console.error(`[proxy] Tool loop guard: conversation ${bridgeKey} exceeded ${MAX_TOOL_ROUNDS} tool rounds on resume, killing bridge`);
    }
    if (!loopGuardTripped && activeBridge.bridge.alive) {
        return handleToolResultResume(activeBridge, toolResults, modelId, bridgeKey);
    }
    // Bridge died, or loop guard tripped — clean up and fall through.
    clearInterval(activeBridge.heartbeatTimer);
    activeBridge.bridge.end();
    return null;
}
/** Clean up a stale bridge that has no pending tool results. */
function cleanupStaleBridge(bridgeKey, activeBridge) {
    if (activeBridge && activeBridges.has(bridgeKey)) {
        clearInterval(activeBridge.heartbeatTimer);
        activeBridge.bridge.end();
        activeBridges.delete(bridgeKey);
    }
}
/** Get or create conversation state for a bridge key. */
function getOrCreateConversationState(bridgeKey) {
    let stored = conversationStates.get(bridgeKey);
    if (!stored) {
        stored = {
            conversationId: crypto.randomUUID(),
            checkpoint: null,
            blobStore: new Map(),
            lastAccessMs: Date.now(),
            toolRounds: 0,
        };
        conversationStates.set(bridgeKey, stored);
    }
    stored.lastAccessMs = Date.now();
    return stored;
}
/**
 * Update tool round counter for the loop guard (t1553).
 * A new user message resets the counter. Tool results without an active
 * bridge (dead bridge fallthrough) increment it.
 */
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
    // Debug logging (t1553) — log what OpenCode sends us
    console.error(`[proxy] handleChatCompletion: model=${modelId}, tools=${tools.length}, toolNames=[${tools.map(t => t.function?.name || '?').join(',')}], userText=${(userText || '').slice(0, 80)}, toolResults=${toolResults.length}, messages=${body.messages?.length || 0}, stream=${body.stream}`);
    if (!userText && toolResults.length === 0) {
        return new Response(JSON.stringify({
            error: {
                message: "No user message found",
                type: "invalid_request_error",
            },
        }), { status: 400, headers: { "Content-Type": "application/json" } });
    }
    const bridgeKey = deriveBridgeKey(modelId, body.messages);
    const activeBridge = activeBridges.get(bridgeKey);
    // Try to resume an active bridge waiting for tool results.
    if (activeBridge && toolResults.length > 0) {
        const resumed = tryResumeBridge(bridgeKey, activeBridge, toolResults, modelId);
        if (resumed) return resumed;
    }
    cleanupStaleBridge(bridgeKey, activeBridge);
    const stored = getOrCreateConversationState(bridgeKey);
    evictStaleConversations();
    updateToolRoundCounter(stored, toolResults, userText, !!activeBridge);
    // Tool loop guard (t1553): if rounds exceeded, disable tools so the
    // model generates a text-only response.
    const toolsExhausted = (stored.toolRounds || 0) >= MAX_TOOL_ROUNDS;
    if (toolsExhausted) {
        console.error(`[proxy] Tool loop guard: conversation ${bridgeKey} exceeded ${MAX_TOOL_ROUNDS} tool rounds, disabling tools`);
    }
    // Do NOT forward OpenAI tools to Cursor as MCP tools (t1553 finding).
    // Sending MCP tools via RequestContext causes Cursor's gRPC agent to
    // enter a tool execution loop that hangs indefinitely — the server
    // sends native tool exec messages (readArgs, shellArgs, etc.), we
    // reject them, but the server never falls through to text generation.
    // Tool calling for Cursor models requires a different approach (e.g.,
    // Nomadcxx-style text prompt flattening with structured text parsing).
    const mcpTools = [];
    console.error(`[proxy] tools from OpenCode: ${tools.length}, mcpTools forwarded: ${mcpTools.length} (MCP forwarding disabled — causes gRPC hang)`);
    const effectiveUserText = userText || (toolResults.length > 0
        ? toolResults.map((r) => r.content).join("\n")
        : "");
    const payload = buildCursorRequest(
        { modelId, systemPrompt, userText: effectiveUserText, turns },
        { conversationId: stored.conversationId, checkpoint: stored.checkpoint, blobStore: stored.blobStore }
    );
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
/** Encode a single conversation turn (user + optional assistant) to bytes. */
function encodeTurn(turn) {
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
    return toBinary(ConversationTurnStructureSchema, turnStructure);
}
/** Build or restore a ConversationStateStructure from turns or a checkpoint. */
function buildConversationState(turns, systemBlobId, checkpoint) {
    if (checkpoint) {
        return fromBinary(ConversationStateStructureSchema, checkpoint);
    }
    return create(ConversationStateStructureSchema, {
        rootPromptMessagesJson: [systemBlobId],
        turns: turns.map(encodeTurn),
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
/**
 * Build a Cursor AgentRunRequest payload.
 * @param {{ modelId: string, systemPrompt: string, userText: string, turns: Array }} req
 * @param {{ conversationId: string, checkpoint: Uint8Array|null, blobStore: Map }} ctx
 */
function buildCursorRequest(req, ctx) {
    const { modelId, systemPrompt, userText, turns } = req;
    const blobStore = new Map(ctx.blobStore ?? []);
    // System prompt → blob store (Cursor requests it back via KV handshake)
    const systemJson = JSON.stringify({ role: "system", content: systemPrompt });
    const systemBytes = new TextEncoder().encode(systemJson);
    const systemBlobId = new Uint8Array(createHash("sha256").update(systemBytes).digest());
    blobStore.set(Buffer.from(systemBlobId).toString("hex"), systemBytes);
    const conversationState = buildConversationState(turns, systemBlobId, ctx.checkpoint);
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
        conversationId: ctx.conversationId,
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
/**
 * @param {object} msg - AgentServerMessage
 * @param {{ blobStore: Map, mcpTools: Array, sendFrame: Function }} transport
 * @param {{ onText: Function, onMcpExec: Function, onCheckpoint: Function }} handlers
 */
function processServerMessage(msg, transport, handlers) {
    const { blobStore, mcpTools, sendFrame } = transport;
    const { onText, onMcpExec, onCheckpoint } = handlers;
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
/** Handle requestContextArgs — provide MCP tools to Cursor. */
function handleRequestContext(execMsg, mcpTools, sendFrame) {
    console.error(`[proxy] requestContextArgs: providing ${mcpTools.length} MCP tools to Cursor`);
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
}
/** Handle mcpArgs — forward tool call to the caller via onMcpExec. */
function handleMcpArgs(execMsg, onMcpExec) {
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
}
/**
 * Reject a native Cursor tool with a "path"-based rejection message.
 * Used for read, ls, write, delete exec types.
 * @param {{ resultCase: string, resultSchema: object, rejectedSchema: object }} schemas
 */
function rejectPathTool(execMsg, schemas, reason, sendFrame) {
    const args = execMsg.message.value;
    const result = create(schemas.resultSchema, {
        result: { case: "rejected", value: create(schemas.rejectedSchema, { path: args.path, reason }) },
    });
    sendExecResult(execMsg, schemas.resultCase, result, sendFrame);
}
/**
 * Reject a shell-type exec with command/workingDirectory fields.
 * @param {{ resultCase: string, resultSchema: object }} schemas
 */
function rejectShellTool(execMsg, schemas, reason, sendFrame) {
    const args = execMsg.message.value;
    const result = create(schemas.resultSchema, {
        result: {
            case: "rejected",
            value: create(ShellRejectedSchema, {
                command: args.command ?? "",
                workingDirectory: args.workingDirectory ?? "",
                reason,
                isReadonly: false,
            }),
        },
    });
    sendExecResult(execMsg, schemas.resultCase, result, sendFrame);
}
/**
 * Reject an exec with an error-type result (grep, writeShellStdin, fetch).
 * @param {{ resultCase: string, resultSchema: object, errorSchema: object }} schemas
 */
function rejectErrorTool(execMsg, schemas, errorFields, sendFrame) {
    const result = create(schemas.resultSchema, {
        result: { case: "error", value: create(schemas.errorSchema, errorFields) },
    });
    sendExecResult(execMsg, schemas.resultCase, result, sendFrame);
}
/**
 * Reject native Cursor tools so the model falls back to MCP tools.
 * Returns true if the exec was handled, false otherwise.
 */
// Static rejection tables — defined once, reused per call.
const PATH_REJECTIONS = {
    readArgs:   { resultCase: "readResult",   resultSchema: ReadResultSchema,   rejectedSchema: ReadRejectedSchema },
    lsArgs:     { resultCase: "lsResult",     resultSchema: LsResultSchema,     rejectedSchema: LsRejectedSchema },
    writeArgs:  { resultCase: "writeResult",  resultSchema: WriteResultSchema,  rejectedSchema: WriteRejectedSchema },
    deleteArgs: { resultCase: "deleteResult", resultSchema: DeleteResultSchema, rejectedSchema: DeleteRejectedSchema },
};
const SHELL_REJECTIONS = {
    shellArgs:                 { resultCase: "shellResult",                resultSchema: ShellResultSchema },
    shellStreamArgs:           { resultCase: "shellResult",                resultSchema: ShellResultSchema },
    backgroundShellSpawnArgs:  { resultCase: "backgroundShellSpawnResult", resultSchema: BackgroundShellSpawnResultSchema },
};
const ERROR_REJECTIONS = {
    grepArgs:           { resultCase: "grepResult",           resultSchema: GrepResultSchema,           errorSchema: GrepErrorSchema },
    writeShellStdinArgs:{ resultCase: "writeShellStdinResult", resultSchema: WriteShellStdinResultSchema, errorSchema: WriteShellStdinErrorSchema },
};
const MISC_RESULT_CASES = {
    listMcpResourcesExecArgs: "listMcpResourcesExecResult",
    readMcpResourceExecArgs:  "readMcpResourceExecResult",
    recordScreenArgs:         "recordScreenResult",
    computerUseArgs:          "computerUseResult",
};
/**
 * Reject native Cursor tools so the model falls back to MCP tools.
 * Returns true if the exec was handled, false otherwise.
 */
function rejectNativeCursorTool(execCase, execMsg, sendFrame) {
    const REJECT_REASON = "Tool not available in this environment. Use the MCP tools provided instead.";
    const pathEntry = PATH_REJECTIONS[execCase];
    if (pathEntry) { rejectPathTool(execMsg, pathEntry, REJECT_REASON, sendFrame); return true; }
    const shellEntry = SHELL_REJECTIONS[execCase];
    if (shellEntry) { rejectShellTool(execMsg, shellEntry, REJECT_REASON, sendFrame); return true; }
    const errorEntry = ERROR_REJECTIONS[execCase];
    if (errorEntry) { rejectErrorTool(execMsg, errorEntry, { error: REJECT_REASON }, sendFrame); return true; }
    if (execCase === "fetchArgs") {
        const args = execMsg.message.value;
        rejectErrorTool(execMsg, { resultCase: "fetchResult", resultSchema: FetchResultSchema, errorSchema: FetchErrorSchema }, { url: args.url ?? "", error: REJECT_REASON }, sendFrame);
        return true;
    }
    // Diagnostics — return empty result (not a rejection)
    if (execCase === "diagnosticsArgs") {
        sendExecResult(execMsg, "diagnosticsResult", create(DiagnosticsResultSchema, {}), sendFrame);
        return true;
    }
    const miscResultCase = MISC_RESULT_CASES[execCase];
    if (miscResultCase) { sendExecResult(execMsg, miscResultCase, create(McpResultSchema, {}), sendFrame); return true; }
    return false;
}
function handleExecMessage(execMsg, mcpTools, sendFrame, onMcpExec) {
    const execCase = execMsg.message.case;
    console.error(`[proxy] execMessage: case=${execCase}`);
    if (execCase === "requestContextArgs") {
        handleRequestContext(execMsg, mcpTools, sendFrame);
        return;
    }
    if (execCase === "mcpArgs") {
        handleMcpArgs(execMsg, onMcpExec);
        return;
    }
    if (rejectNativeCursorTool(execCase, execMsg, sendFrame)) {
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
/** Build SSE sender helpers bound to a ReadableStream controller. */
function createSSESenders(controller, completionId, created, modelId) {
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
    return { sendSSE, sendDone, closeController, makeChunk };
}
/** Flush tag filter output and send any buffered reasoning/content as SSE. */
function flushTagFilterToSSE(tagFilter, makeChunk, sendSSE) {
    const flushed = tagFilter.flush();
    if (flushed.reasoning)
        sendSSE(makeChunk({ reasoning_content: flushed.reasoning }));
    if (flushed.content)
        sendSSE(makeChunk({ content: flushed.content }));
}
/** Merge blobStore entries into stored conversation state. */
function mergeBlobStoreIntoState(bridgeKey, blobStore) {
    const stored = conversationStates.get(bridgeKey);
    if (stored) {
        for (const [k, v] of blobStore)
            stored.blobStore.set(k, v);
        stored.lastAccessMs = Date.now();
    }
}
/**
 * Create an SSE streaming Response that reads from a live bridge.
 * @param {{ bridge: object, heartbeatTimer: number, blobStore: Map, mcpTools: Array }} bridgeCtx
 * @param {string} modelId
 * @param {string} bridgeKey
 */
function createBridgeStreamResponse(bridgeCtx, modelId, bridgeKey) {
    const { bridge, heartbeatTimer, blobStore, mcpTools } = bridgeCtx;
    const completionId = `chatcmpl-${crypto.randomUUID().replace(/-/g, "").slice(0, 28)}`;
    const created = Math.floor(Date.now() / 1000);
    const stream = new ReadableStream({
        start(controller) {
            const { sendSSE, sendDone, closeController, makeChunk } = createSSESenders(controller, completionId, created, modelId);
            const state = {
                toolCallIndex: 0,
                pendingExecs: [],
            };
            const tagFilter = createThinkingTagFilter();
            let mcpExecReceived = false;
            const processChunk = createConnectFrameParser((messageBytes) => {
                try {
                    const serverMessage = fromBinary(AgentServerMessageSchema, messageBytes);
                    processServerMessage(serverMessage, { blobStore, mcpTools, sendFrame: (data) => bridge.write(data) }, {
                        onText(text, isThinking) {
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
                        onMcpExec(exec) {
                            state.pendingExecs.push(exec);
                            mcpExecReceived = true;
                            flushTagFilterToSSE(tagFilter, makeChunk, sendSSE);
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
                        },
                        onCheckpoint(checkpointBytes) {
                            const stored = conversationStates.get(bridgeKey);
                            if (stored) {
                                stored.checkpoint = checkpointBytes;
                                stored.lastAccessMs = Date.now();
                            }
                        },
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
                mergeBlobStoreIntoState(bridgeKey, blobStore);
                if (!mcpExecReceived) {
                    flushTagFilterToSSE(tagFilter, makeChunk, sendSSE);
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
    return createBridgeStreamResponse({ bridge, heartbeatTimer, blobStore: payload.blobStore, mcpTools: payload.mcpTools }, modelId, bridgeKey);
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
    return createBridgeStreamResponse({ bridge, heartbeatTimer, blobStore, mcpTools }, modelId, bridgeKey);
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
/**
 * Handle a tool call exec during non-streaming response collection.
 * Resolves the promise with tool_calls and parks the bridge for continuation.
 * @param {{ bridge, heartbeatTimer, payload, bridgeKey }} bridgeCtx
 * @param {{ state, tagFilter, fullTextRef, resolve }} collectCtx
 */
function handleNonStreamToolCall(exec, bridgeCtx, collectCtx) {
    const { bridge, heartbeatTimer, payload, bridgeKey } = bridgeCtx;
    const { state, tagFilter, fullTextRef, resolve } = collectCtx;
    state.pendingExecs.push(exec);
    const flushed = tagFilter.flush();
    fullTextRef.value += flushed.content;
    state.toolCallIndex++;
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
    resolve({ text: fullTextRef.value, toolCalls });
}
async function collectFullResponse(payload, accessToken, bridgeKey) {
    const { promise, resolve } = Promise.withResolvers();
    const fullTextRef = { value: "" };
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
            processServerMessage(serverMessage, { blobStore: payload.blobStore, mcpTools: payload.mcpTools, sendFrame: (data) => bridge.write(data) }, {
                onText(text, isThinking) {
                    if (isThinking)
                        return;
                    const { content } = tagFilter.process(text);
                    fullTextRef.value += content;
                },
                onMcpExec(exec) {
                    // Tool call received — resolve immediately with tool_calls
                    // and keep the bridge alive for tool result continuation.
                    if (resolved) return;
                    resolved = true;
                    handleNonStreamToolCall(exec, { bridge, heartbeatTimer, payload, bridgeKey }, { state, tagFilter, fullTextRef, resolve });
                },
                onCheckpoint(checkpointBytes) {
                    const stored = conversationStates.get(bridgeKey);
                    if (stored) {
                        stored.checkpoint = checkpointBytes;
                        stored.lastAccessMs = Date.now();
                    }
                },
            });
        }
        catch {
            // Skip
        }
    }, () => { }));
    bridge.onClose(() => {
        clearInterval(heartbeatTimer);
        mergeBlobStoreIntoState(bridgeKey, payload.blobStore);
        if (!resolved) {
            resolved = true;
            const flushed = tagFilter.flush();
            fullTextRef.value += flushed.content;
            resolve({ text: fullTextRef.value, toolCalls: null });
        }
    });
    return promise;
}
