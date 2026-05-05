// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const DEFAULT_OVERLOAD_RETRY_DELAYS_MS = [3_000, 10_000, 30_000, 60_000, 120_000, 180_000];
const OVERLOAD_MARKERS = ["service_unavailable_error", "server_is_overloaded", "servers are currently overloaded"];
const OVERLOAD_RECOVERY_NOTE = "aidevops attempted automatic recovery for this OpenAI overload. If the request still stopped, use the prepared continuation prompt to pick up where the work left off.";
const STREAM_CONTENT_MARKERS = [
  "response.output_text.delta",
  "response.function_call_arguments.delta",
  "response.code_interpreter_call_code.delta",
  "response.reasoning_summary_text.delta",
];

export function overloadRetryDelaysMs() {
  const raw = process.env.AIDEVOPS_OPENAI_OVERLOAD_RETRY_DELAYS_MS || "";
  const parsed = raw
    .split(",")
    .map((part) => Number.parseInt(part.trim(), 10))
    .filter((value) => Number.isFinite(value) && value >= 0);
  return parsed.length > 0 ? parsed : DEFAULT_OVERLOAD_RETRY_DELAYS_MS;
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function isOpenAIOverloadText(text) {
  const lowered = String(text || "").toLowerCase();
  return OVERLOAD_MARKERS.some((marker) => lowered.includes(marker));
}

function isOpenAIStreamContentText(text) {
  return STREAM_CONTENT_MARKERS.some((marker) => String(text || "").includes(marker));
}

function enqueueChunks(controller, chunks) {
  for (const chunk of chunks) controller.enqueue(chunk);
}

export function formatRetryDelay(delayMs) {
  if (delayMs < 1000) return `${delayMs}ms`;
  const seconds = Math.round(delayMs / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  return remainder > 0 ? `${minutes}m ${remainder}s` : `${minutes}m`;
}

function appendRecoveryNote(message) {
  const text = String(message || "").trim();
  if (text.includes(OVERLOAD_RECOVERY_NOTE)) return text;
  return text ? `${text}\n\n${OVERLOAD_RECOVERY_NOTE}` : OVERLOAD_RECOVERY_NOTE;
}

function appendRecoveryNoteToPayload(payload) {
  if (!payload || typeof payload !== "object") return false;
  const error = payload.error && typeof payload.error === "object" ? payload.error : payload;
  if (!isOpenAIOverloadText([error.code, error.type, error.message].join(" "))) return false;
  error.message = appendRecoveryNote(error.message || "OpenAI is overloaded. Please try again later.");
  return true;
}

function annotateOpenAIOverloadText(text) {
  const raw = String(text || "");
  const lines = raw.split("\n");
  let changed = false;
  const annotated = lines.map((line) => {
    if (!line.startsWith("data: ")) return line;
    const data = line.slice(6);
    try {
      const payload = JSON.parse(data);
      if (!appendRecoveryNoteToPayload(payload)) return line;
      changed = true;
      return `data: ${JSON.stringify(payload)}`;
    } catch {
      return line;
    }
  }).join("\n");

  if (changed) return annotated;

  try {
    const payload = JSON.parse(raw);
    if (appendRecoveryNoteToPayload(payload)) return JSON.stringify(payload);
  } catch {
    // Not a standalone JSON payload; leave unchanged.
  }
  return raw;
}

async function pipeRemainingStream(reader, controller) {
  while (true) {
    const { done, value } = await reader.read();
    if (done) return controller.close();
    controller.enqueue(value);
  }
}

async function inspectStreamPrefix(reader, controller, decoder, retryAvailable) {
  const buffered = [];
  let bufferedText = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      enqueueChunks(controller, buffered);
      controller.close();
      return "closed";
    }

    buffered.push(value);
    bufferedText += decoder.decode(value, { stream: true });

    if (isOpenAIOverloadText(bufferedText)) {
      if (!retryAvailable) {
        controller.enqueue(new TextEncoder().encode(annotateOpenAIOverloadText(bufferedText)));
        return "pipe";
      }
      await reader.cancel().catch(() => {});
      return "retry";
    }

    if (isOpenAIStreamContentText(bufferedText) || bufferedText.length > 65_536) {
      enqueueChunks(controller, buffered);
      return "pipe";
    }
  }
}

async function retryOpenAIOverloadStream(ctx) {
  const { originalFetch, response, retryInput, init, controller, retryDelays, buildRetryRequest, onRetry } = ctx;
  const decoder = new TextDecoder();
  let currentResponse = response;

  for (let attempt = 0; ; attempt += 1) {
    const reader = currentResponse.body.getReader();
    const outcome = await inspectStreamPrefix(reader, controller, decoder, attempt < retryDelays.length);
    if (outcome === "closed") return;
    if (outcome === "pipe") return pipeRemainingStream(reader, controller);

    const delayMs = retryDelays[attempt];
    console.error(`[aidevops] OpenAI provider: overloaded stream error — retrying request (${attempt + 1}/${retryDelays.length})`);
    await onRetry?.({
      attempt: attempt + 1,
      totalAttempts: retryDelays.length,
      delayMs,
      delayLabel: formatRetryDelay(delayMs),
    });
    if (delayMs > 0) await sleep(delayMs);
    currentResponse = await originalFetch(buildRetryRequest(retryInput), init);
    if (!currentResponse.body) return controller.error(new Error(`OpenAI provider: retry response missing body (status: ${currentResponse.status})`));
  }
}

export async function annotateOpenAIOverloadResponse(response) {
  try {
    const text = await response.text();
    const annotated = annotateOpenAIOverloadText(text);
    const headers = new Headers(response.headers);
    headers.delete("content-length");
    return new Response(annotated, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  } catch {
    return response;
  }
}

export function wrapOpenAIOverloadStream(ctx) {
  const { response } = ctx;
  if (!response.body) return response;
  const contentType = response.headers?.get?.("content-type") || "";
  if (!contentType.includes("text/event-stream")) return response;

  const retryDelays = overloadRetryDelaysMs();
  const stream = new ReadableStream({
    async start(controller) {
      try {
        await retryOpenAIOverloadStream({ ...ctx, controller, retryDelays });
      } catch (err) {
        controller.error(err);
      }
    },
  });

  return new Response(stream, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}
