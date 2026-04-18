/**
 * Request/response transformation helpers for provider-auth.mjs.
 * Extracted to keep per-file complexity below the threshold.
 */

import { getAnthropicUserAgent } from "./oauth-pool.mjs";
import { buildBillingHeader, serializeWithKeyOrder, loadCCHConstants, computeBodyHash } from "./provider-auth-cch.mjs";
import { textResponse } from "./response-helpers.mjs";

// ---------------------------------------------------------------------------
// Tool name namespace
// ---------------------------------------------------------------------------

export const TOOL_PREFIX = "mcp__aidevops__";

export const REQUIRED_BETAS = [
  "oauth-2025-04-20",
  "interleaved-thinking-2025-05-14",
  "prompt-caching-scope-2026-01-05",
  "claude-code-20250219",
];

export const DEPRECATED_BETAS = new Set([
  "code-execution-2025-01-24",
  "extended-cache-ttl-2025-04-11",
]);

// ---------------------------------------------------------------------------
// Header building
// ---------------------------------------------------------------------------

function copyHeadersInstance(target, source) {
  source.forEach((value, key) => target.set(key, value));
}

function copyHeadersArray(target, entries) {
  for (const [key, value] of entries) {
    if (typeof value !== "undefined") target.set(key, String(value));
  }
}

function copyHeadersObject(target, obj) {
  for (const [key, value] of Object.entries(obj)) {
    if (typeof value !== "undefined") target.set(key, String(value));
  }
}

function mergeInitHeaders(target, initHeaders) {
  if (!initHeaders) return;
  if (initHeaders instanceof Headers) copyHeadersInstance(target, initHeaders);
  else if (Array.isArray(initHeaders)) copyHeadersArray(target, initHeaders);
  else copyHeadersObject(target, initHeaders);
}

function mergeBetaHeaders() {
  return REQUIRED_BETAS.join(",");
}

/**
 * Build outgoing request headers with auth, betas, stainless metadata.
 * @param {Request|string|URL} input @param {RequestInit} init @param {string} accessToken
 */
export function buildRequestHeaders(input, init, accessToken) {
  const requestHeaders = new Headers();
  if (input instanceof Request) input.headers.forEach((value, key) => requestHeaders.set(key, value));
  mergeInitHeaders(requestHeaders, init?.headers);
  requestHeaders.set("authorization", `Bearer ${accessToken}`);
  requestHeaders.set("anthropic-beta", mergeBetaHeaders());
  requestHeaders.set("anthropic-dangerous-direct-browser-access", "true");
  requestHeaders.set("anthropic-version", "2023-06-01");
  requestHeaders.set("user-agent", getAnthropicUserAgent());
  requestHeaders.set("x-app", "cli");
  requestHeaders.set("accept", "application/json");
  requestHeaders.set("content-type", "application/json");
  if (!requestHeaders.has("x-claude-code-session-id")) {
    requestHeaders.set("x-claude-code-session-id", globalThis._claudeCodeSessionId ??= crypto.randomUUID());
  }
  requestHeaders.set("x-client-request-id", crypto.randomUUID());
  const { version } = loadCCHConstants();
  requestHeaders.set("X-Stainless-Arch", process.arch === "arm64" ? "arm64" : "x64");
  requestHeaders.set("X-Stainless-Lang", "js");
  requestHeaders.set("X-Stainless-OS", process.platform === "darwin" ? "Mac OS X" : "Linux");
  requestHeaders.set("X-Stainless-Package-Version", "0.81.0");
  requestHeaders.set("X-Stainless-Retry-Count", "0");
  requestHeaders.set("X-Stainless-Runtime", "node");
  requestHeaders.set("X-Stainless-Runtime-Version", process.version);
  requestHeaders.set("X-Stainless-Timeout", "600");
  requestHeaders.delete("x-api-key");
  requestHeaders.delete("x-session-affinity");
  return requestHeaders;
}

// ---------------------------------------------------------------------------
// Body transformation
// ---------------------------------------------------------------------------

const TAG_RENAMES = [
  [/<directories>/g, "<working_dirs>"],     [/<\/directories>/g, "</working_dirs>"],
  [/<available_skills>/g, "<skill_list>"],   [/<\/available_skills>/g, "</skill_list>"],
  [/<env>/g, "<environment>"],               [/<\/env>/g, "</environment>"],
];

function sanitizeSystemPrompt(system) {
  return system.map((item) => {
    if (item.type !== "text" || !item.text) return item;
    let text = item.text.replace(/OpenCode/g, "Claude Code").replace(/opencode/gi, "Claude");
    for (const [pattern, replacement] of TAG_RENAMES) text = text.replace(pattern, replacement);
    return { ...item, text };
  });
}

function prefixToolNames(tools) {
  return tools.map((tool) => {
    if (!tool.name || tool.name.startsWith("mcp__")) return tool;
    return { ...tool, name: `${TOOL_PREFIX}${tool.name}` };
  });
}

/**
 * Intent tracing field name — must match INTENT_FIELD in intent-tracing.mjs.
 * Duplicated here (not imported) because this module runs inside the
 * request-transform hot path and must have no module-graph surprises.
 */
const INTENT_PARAM_NAME = "agent__intent";

const INTENT_PARAM_SCHEMA = Object.freeze({
  type: "string",
  description:
    "Intent tracing (observability). One sentence in present participle form describing " +
    "your intent for this tool call (e.g., \"Reading the file to understand the existing schema\"). " +
    "No trailing period. Stripped before tool execution — used only for debugging and audit trails.",
});

/**
 * Inject agent__intent as an optional property on every tool's input_schema.
 *
 * Anthropic's Messages API validates tool-call arguments against each tool's
 * declared input_schema and strips unknown properties before delivering the
 * tool_use block to the client. Without this declaration, the system-prompt
 * instruction to "include agent__intent" is honored by the LLM but dropped
 * by the API before reaching opencode's tool.execute.before hook — which is
 * why plugins/opencode-aidevops/intent-tracing.mjs sees empty args for every
 * Anthropic toolu_* call.
 *
 * OpenAI preserves unknown tool-arg properties, so call_* IDs kept working.
 * This fix is Anthropic-only (which is what this provider-auth module runs).
 *
 * Keep additive: never modify `required`; never touch tools that lack a
 * standard JSON-Schema `type: "object"` input_schema; never overwrite an
 * existing `agent__intent` property (a future tool might legitimately use
 * that name for its own purposes).
 *
 * @param {Array<any>} tools
 * @returns {Array<any>}
 */
export function injectIntentParameter(tools) {
  return tools.map((tool) => {
    const schema = tool?.input_schema;
    if (!schema || schema.type !== "object") return tool;
    const properties = schema.properties ?? {};
    if (Object.prototype.hasOwnProperty.call(properties, INTENT_PARAM_NAME)) {
      return tool;
    }
    return {
      ...tool,
      input_schema: {
        ...schema,
        properties: {
          ...properties,
          [INTENT_PARAM_NAME]: INTENT_PARAM_SCHEMA,
        },
      },
    };
  });
}

function prefixToolUseBlocks(messages) {
  return messages.map((msg) => {
    if (!msg.content || !Array.isArray(msg.content)) return msg;
    return {
      ...msg,
      content: msg.content.map((block) => {
        if (block.type === "tool_use" && block.name && !block.name.startsWith("mcp__")) {
          return { ...block, name: `${TOOL_PREFIX}${block.name}` };
        }
        return block;
      }),
    };
  });
}

function isAdaptiveThinkingModel(model) {
  if (!model) return false;
  return /claude-[a-z]+-4[-.]6/i.test(model);
}

function applyBodyTransforms(parsed) {
  const billingText = buildBillingHeader(parsed);
  if (!Array.isArray(parsed.system)) parsed.system = [];
  parsed.system = parsed.system.filter(
    (b) => !(b.type === "text" && b.text?.startsWith("x-anthropic-billing-header:")),
  );
  parsed.system.unshift({ type: "text", text: billingText });
  parsed.system = sanitizeSystemPrompt(parsed.system);
  if (Array.isArray(parsed.tools)) {
    parsed.tools = prefixToolNames(parsed.tools);
    parsed.tools = injectIntentParameter(parsed.tools);
  }
  if (Array.isArray(parsed.messages)) parsed.messages = prefixToolUseBlocks(parsed.messages);
  if (isAdaptiveThinkingModel(parsed.model)) {
    if (!parsed.thinking || parsed.thinking.type !== "adaptive") parsed.thinking = { type: "adaptive" };
    if (parsed.temperature !== undefined && parsed.temperature !== 1) parsed.temperature = 1;
  }
}

/**
 * Transform the request body: sanitize system prompt, prefix tool names.
 * @param {string|null|undefined} body @returns {string|null|undefined}
 */
export function transformRequestBody(body) {
  if (!body || typeof body !== "string") return body;
  try {
    const parsed = JSON.parse(body);
    applyBodyTransforms(parsed);
    const serialized = serializeWithKeyOrder(parsed);
    void computeBodyHash;
    return serialized;
  } catch {
    return body;
  }
}

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

function parseRequestUrl(input) {
  try {
    if (typeof input === "string" || input instanceof URL) return new URL(input.toString());
    if (input instanceof Request) return new URL(input.url);
  } catch { /* ignore */ }
  return null;
}

function rewriteUrlWithBeta(url, input) {
  url.searchParams.set("beta", "true");
  return input instanceof Request ? new Request(url.toString(), input) : url;
}

/**
 * Add ?beta=true to /v1/messages requests if not already present.
 * @param {Request|string|URL} input @returns {Request|URL|string}
 */
export function addBetaQueryParam(input) {
  const requestUrl = parseRequestUrl(input);
  if (!requestUrl || requestUrl.pathname !== "/v1/messages" || requestUrl.searchParams.has("beta")) return input;
  return rewriteUrlWithBeta(requestUrl, input);
}

// ---------------------------------------------------------------------------
// Response stream transformation
// ---------------------------------------------------------------------------

function stripMcpPrefix(text) {
  return text.replace(/"name"\s*:\s*"mcp__aidevops__([^"]+)"/g, '"name":"$1"');
}

// t2121: buffer incomplete SSE lines across chunk boundaries. The previous
// implementation ran stripMcpPrefix() on each decoded chunk in isolation;
// when Anthropic's SSE stream split a tool name across two chunks, neither
// chunk matched the regex and the reassembled stream passed through to
// OpenCode with the unstripped prefix, causing tool calls to be rejected
// as "unavailable tool" — workers exited with no_activity at ~30s.
//
// SSE is line-delimited and Anthropic emits each event as a single-line
// JSON `data: {...}\n` frame. JSON strings cannot contain literal newlines
// so any "mcp__aidevops__XYZ" token is always on one line. Buffering up to
// the last newline in the accumulated stream is provably safe: the regex
// only runs against complete lines, and incomplete tails are carried into
// the next chunk until their terminating newline arrives.
function makeStreamPullHandler(reader, decoder, encoder) {
  let pending = "";
  return async function pull(controller) {
    // Loop over upstream reads until we emit a complete line (or EOF).
    // ReadableStream spec requires pull() to enqueue-or-close before
    // returning. On EOF we always enqueue+close: the terminal enqueue may
    // carry a buffered partial-line tail (defensive — well-formed SSE
    // ends on a newline so pending is typically empty) or an empty chunk.
    for (;;) {
      const { done, value } = await reader.read();
      if (done) {
        const tail = pending;
        pending = "";
        controller.enqueue(encoder.encode(stripMcpPrefix(tail)));
        controller.close();
        return;
      }
      pending += decoder.decode(value, { stream: true });
      const nl = pending.lastIndexOf("\n");
      if (nl < 0) continue;
      const emit = pending.slice(0, nl + 1);
      pending = pending.slice(nl + 1);
      controller.enqueue(encoder.encode(stripMcpPrefix(emit)));
      return;
    }
  };
}

/**
 * Wrap a response body stream to strip mcp_ prefix from tool names.
 * @param {Response} response @returns {Response}
 */
export function transformResponseStream(response) {
  if (!response.body) return response;
  const reader = response.body.getReader();
  const stream = new ReadableStream({
    pull: makeStreamPullHandler(reader, new TextDecoder(), new TextEncoder()),
  });
  return textResponse(stream, { status: response.status, statusText: response.statusText, headers: response.headers });
}
