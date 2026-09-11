// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const MAX_SSE_BUFFER_CHARS = 96 * 1024 * 1024;
const MAX_SSE_TOTAL_BYTES = 128 * 1024 * 1024;
const TERMINAL_SSE_EVENT_TYPES = new Set([
  "error",
  "response.failed",
  "response.incomplete",
  "response.completed",
]);
const TERMINAL_SSE_DEFAULT_ERRORS = new Map([
  ["response.completed", {
    code: "image_missing",
    message: "provider completed the response without an image result",
  }],
]);

export function redactProviderDetail(value) {
  return String(value || "")
    .replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]")
    .replace(/\bsk-[A-Za-z0-9_-]+\b/g, "[REDACTED]")
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "[REDACTED]")
    .slice(0, 300);
}

async function enforceTerminalSseEvent(reader, event) {
  if (!TERMINAL_SSE_EVENT_TYPES.has(event.type)) return null;
  const providerError = event.error || event.response?.error || event.response?.incomplete_details || {};
  const defaultError = TERMINAL_SSE_DEFAULT_ERRORS.get(event.type) || {};
  const code = [providerError.code, providerError.type, providerError.reason, event.code, defaultError.code]
    .find(Boolean) || "";
  const message = [providerError.message, event.message, defaultError.message].find(Boolean) || "";
  const detail = [code, message].filter(Boolean).map(redactProviderDetail).join(": ");
  const error = new Error(`OpenAI oauth image request failed${detail ? `: ${detail}` : `: ${event.type}`}.`);
  error.code = redactProviderDetail(code);
  error.eventType = event.type;
  await cancelSseReader(reader);
  throw error;
}

async function parseSseBlock(reader, block) {
  const data = block
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trimStart())
    .join("\n");
  if (!data || data === "[DONE]") return "";
  let event;
  try {
    event = Object(JSON.parse(data));
  } catch {
    return "";
  }
  let result = "";
  if (
    event.type === "response.output_item.done"
    && event.item?.type === "image_generation_call"
    && typeof event.item.result === "string"
  ) {
    result = event.item.result;
  }
  if (event.type === "response.completed" && Array.isArray(event.response?.output)) {
    const image = event.response.output.find(
      (item) => item?.type === "image_generation_call" && typeof item.result === "string",
    );
    result = image?.result || "";
  }
  if (result) return result;
  await enforceTerminalSseEvent(reader, event);
  return "";
}

function takeNextSseBlock(pending) {
  const delimiter = pending.match(/\r?\n\r?\n/);
  if (!delimiter || delimiter.index === undefined) return null;
  const end = delimiter.index + delimiter[0].length;
  return { block: pending.slice(0, delimiter.index), rest: pending.slice(end) };
}

async function cancelSseReader(reader) {
  await reader.cancel().catch(() => {});
}

async function consumeSseBlocks(reader, pending) {
  let next;
  while ((next = takeNextSseBlock(pending))) {
    pending = next.rest;
    if (next.block.length > MAX_SSE_BUFFER_CHARS) {
      await cancelSseReader(reader);
      throw new Error("OAuth image event exceeded the safe event-stream limit.");
    }
    const result = await parseSseBlock(reader, next.block);
    if (result) return { pending, result };
  }
  return { pending, result: "" };
}

async function enforceSseLimit(reader, exceeded, message) {
  if (!exceeded) return;
  await cancelSseReader(reader);
  throw new Error(message);
}

export async function parseImageSse(stream) {
  if (!stream?.getReader) throw new Error("OAuth image response did not include an event stream.");
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let pending = "";
  let totalBytes = 0;
  while (true) {
    const { done, value } = await reader.read();
    totalBytes += value?.byteLength || 0;
    await enforceSseLimit(
      reader,
      totalBytes > MAX_SSE_TOTAL_BYTES,
      "OAuth image response exceeded the safe event-stream limit.",
    );
    pending += decoder.decode(value || new Uint8Array(), { stream: !done });
    const consumed = await consumeSseBlocks(reader, pending);
    pending = consumed.pending;
    if (consumed.result) {
      await cancelSseReader(reader);
      return consumed.result;
    }
    await enforceSseLimit(
      reader,
      pending.length > MAX_SSE_BUFFER_CHARS,
      "OAuth image response exceeded the safe event-stream limit.",
    );
    if (done) break;
  }
  const finalResult = await parseSseBlock(reader, pending);
  if (finalResult) return finalResult;
  throw new Error("OAuth image response did not contain a completed image.");
}
