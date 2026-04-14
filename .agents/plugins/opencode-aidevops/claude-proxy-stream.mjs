// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * SSE stream-event processing for the Claude CLI proxy.
 *
 * Extracted from claude-proxy.mjs as part of t2070 to drop file complexity
 * and the `processStreamEvent` cyclomatic count below the qlty thresholds.
 *
 * The proxy reads JSON-lines from `claude --output-format stream-json` on the
 * child's stdout and translates each event into OpenAI-compatible chunks that
 * OpenCode's @ai-sdk/openai-compatible provider understands. The original
 * implementation handled all event types in a single 38-branch function; this
 * module dispatches to per-event-type handlers via a lookup table so each
 * handler stays small enough to reason about in isolation.
 *
 * Public surface (consumed by claude-proxy.mjs):
 *   - createOpenAIChunk(id, created, model, delta, finishReason)
 *   - processStreamEvent(event, ctx)  — main dispatcher
 *   - isCommitTrigger(event)          — probe-phase commit decision
 *
 * `ctx` is the per-stream session object created in claude-proxy.mjs. It must
 * provide `completionId`, `created`, `model`, `send`, `seenToolUseIds` (Map),
 * `seenTaskIds` (Set), `seenToolResults` (Set), `finishSent`, `textChunkCount`,
 * and `textCharCount`. Handlers mutate `ctx` directly.
 */

/**
 * Build an OpenAI-style SSE chunk.
 * @param {string} id
 * @param {number} created
 * @param {string} model
 * @param {object} delta
 * @param {string|null} [finishReason]
 */
export function createOpenAIChunk(id, created, model, delta, finishReason = null) {
  return {
    id,
    object: "chat.completion.chunk",
    created,
    model,
    choices: [{ index: 0, delta, finish_reason: finishReason }],
  };
}

/**
 * Tool-use input fields included in the status-feed summary, in display
 * order. Each entry is `{ key, transform? }` — `transform` post-processes
 * the raw string (e.g. truncation, prefixing). Adding a new tool just means
 * appending an entry here.
 */
const TOOL_INPUT_SUMMARY_FIELDS = [
  { key: "command" },                                          // Bash
  { key: "filePath" },                                         // Read / Edit / Write
  { key: "pattern" },                                          // Glob
  { key: "regex" },                                            // Grep
  { key: "description" },                                      // Bash / Task description
  { key: "prompt", transform: (v) => v.slice(0, 120) },        // Task prompt (truncated)
  { key: "subagent_type", transform: (v) => `type=${v}` },     // Task subagent type
];

/**
 * Summarise a tool-use input block into a short single-line label for the
 * status feed. Only the most informative fields are included to keep the
 * stream legible without leaking full prompts.
 */
function summarizeToolInput(input) {
  if (!input || typeof input !== "object") return "";
  const parts = [];
  for (const { key, transform } of TOOL_INPUT_SUMMARY_FIELDS) {
    const raw = input[key];
    if (typeof raw !== "string") continue;
    parts.push(transform ? transform(raw) : raw);
  }
  return parts.filter(Boolean).join(" — ");
}

function formatStatusLine(label, detail = "") {
  return detail ? `[${label}] ${detail}\n` : `[${label}]\n`;
}

/**
 * Send a content delta to the consumer.
 * @param {object} ctx
 * @param {string} content
 */
function sendContent(ctx, content) {
  ctx.send(createOpenAIChunk(ctx.completionId, ctx.created, ctx.model, { content }));
}

/**
 * Send a status-line content delta with [Label] detail formatting.
 */
function sendStatusLine(ctx, label, detail) {
  sendContent(ctx, formatStatusLine(label, detail));
}

// ---------------------------------------------------------------------------
// Per-event-type handlers
// ---------------------------------------------------------------------------

/** stream_event → content_block_delta (text + thinking) */
function handleContentBlockDelta(inner, ctx) {
  const delta = inner.delta;
  if (delta?.type === "text_delta" && delta.text) {
    ctx.textChunkCount += 1;
    ctx.textCharCount += delta.text.length;
    sendContent(ctx, delta.text);
    return;
  }
  if (delta?.type === "thinking_delta" && delta.thinking) {
    ctx.send(createOpenAIChunk(ctx.completionId, ctx.created, ctx.model, {
      reasoning_content: delta.thinking,
    }));
  }
}

/** stream_event → message_delta (terminal stop_reason) */
function handleMessageDelta(inner, ctx) {
  if (inner.delta?.stop_reason && !ctx.finishSent) {
    ctx.finishSent = true;
    ctx.send(createOpenAIChunk(ctx.completionId, ctx.created, ctx.model, {}, "stop"));
  }
}

/** stream_event dispatcher (groups content_block_delta + message_delta) */
function handleStreamEvent(event, ctx) {
  const inner = event.event;
  if (!inner) return;
  if (inner.type === "content_block_delta") {
    handleContentBlockDelta(inner, ctx);
    return;
  }
  if (inner.type === "message_delta") {
    handleMessageDelta(inner, ctx);
  }
}

/** assistant message — emit one [Tool: name] line per new tool_use block */
function handleAssistant(event, ctx) {
  if (!Array.isArray(event.message?.content)) return;
  for (const block of event.message.content) {
    if (block?.type !== "tool_use" || !block.id) continue;
    if (ctx.seenToolUseIds.has(block.id)) continue;
    ctx.seenToolUseIds.set(block.id, block.name || "unknown");
    sendStatusLine(ctx, `Tool: ${block.name || "unknown"}`, summarizeToolInput(block.input));
  }
}

/** system → task_started subagent dispatch */
function handleTaskStarted(event, ctx) {
  if (!event.task_id) return;
  const key = `start:${event.task_id}`;
  if (ctx.seenTaskIds.has(key)) return;
  ctx.seenTaskIds.add(key);
  sendStatusLine(ctx, "Subagent started", event.description || event.prompt || event.task_id);
}

/** system → task_notification subagent completion */
function handleTaskNotification(event, ctx) {
  if (!event.task_id) return;
  const key = `done:${event.task_id}`;
  if (ctx.seenTaskIds.has(key)) return;
  ctx.seenTaskIds.add(key);
  sendStatusLine(ctx, "Subagent completed", event.summary || event.task_id);
}

/** system event dispatcher */
function handleSystem(event, ctx) {
  if (event.subtype === "task_started") {
    handleTaskStarted(event, ctx);
    return;
  }
  if (event.subtype === "task_notification") {
    handleTaskNotification(event, ctx);
  }
}

/** Extract a printable preview from a tool_use_result payload. */
function extractToolResultPreview(toolResult) {
  if (Array.isArray(toolResult.content)) {
    return toolResult.content.map((item) => item?.text).filter(Boolean).join(" ");
  }
  return toolResult.stdout || "";
}

/** Resolve the tool's friendly name via the dedup map of prior tool_use ids. */
function resolveToolResultName(event, ctx) {
  const toolUseId = event.message?.content?.[0]?.tool_use_id;
  if (toolUseId && ctx.seenToolUseIds.has(toolUseId)) {
    return ctx.seenToolUseIds.get(toolUseId);
  }
  return "unknown";
}

/** Both the result wrapper and the inner content can flag an error state. */
function isToolResultError(event, toolResult) {
  if (toolResult.is_error === true) return true;
  return event.message?.content?.[0]?.is_error === true;
}

/**
 * user → tool_use_result preview line. Correlates the tool name via the
 * `tool_use_id` from the message content so the status line reads
 * `[Tool result: Bash]` rather than `[Tool result: unknown]`.
 */
function handleUserToolResult(event, ctx) {
  if (!event.uuid || !event.tool_use_result) return;
  if (ctx.seenToolResults.has(event.uuid)) return;
  ctx.seenToolResults.add(event.uuid);

  const preview = extractToolResultPreview(event.tool_use_result);
  if (!preview) return;

  const toolName = resolveToolResultName(event, ctx);
  const isError = isToolResultError(event, event.tool_use_result);
  const label = isError ? `Tool error: ${toolName}` : `Tool result: ${toolName}`;
  sendStatusLine(ctx, label, preview.slice(0, 500));
}

// ---------------------------------------------------------------------------
// Top-level event dispatcher
// ---------------------------------------------------------------------------

/**
 * Lookup table: event.type → handler(event, ctx). Stored as a Map (not a
 * plain object) so the dispatcher uses safe `.get()` lookup instead of
 * computed property access on a user-controlled key.
 */
const EVENT_HANDLERS = new Map([
  ["stream_event", handleStreamEvent],
  ["assistant", handleAssistant],
  ["system", handleSystem],
  ["user", handleUserToolResult],
]);

/**
 * Process a single parsed stream-json event and emit the corresponding
 * OpenAI chunk(s). Handlers mutate `ctx` directly (counters, dedup sets,
 * finishSent flag). Events with no registered handler are ignored — the
 * proxy is intentionally permissive about new event types.
 */
export function processStreamEvent(event, ctx) {
  if (!event?.type) return;
  const handler = EVENT_HANDLERS.get(event.type);
  if (handler) handler(event, ctx);
}

/**
 * Returns true if a probe-phase event is enough evidence to commit to the
 * current account (i.e. the request is actually streaming content rather
 * than rate-limited). This covers:
 *   - any content_block_start / content_block_delta
 *   - the initial message_start that carries usage data
 */
export function isCommitTrigger(event) {
  if (event?.type !== "stream_event") return false;
  const innerType = event.event?.type;
  if (innerType === "content_block_start" || innerType === "content_block_delta") return true;
  if (innerType === "message_start" && event.event?.message?.usage) return true;
  return false;
}
