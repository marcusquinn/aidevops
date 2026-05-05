// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const OVERLOAD_MARKERS = ["service_unavailable_error", "server_is_overloaded", "servers are currently overloaded"];
const OVERLOAD_RECOVERY_NOTE = "aidevops attempted automatic recovery for this OpenAI overload. If the request still stopped, use the prepared continuation prompt to pick up where the work left off.";

export function isOpenAIOverloadText(text) {
  const lowered = String(text || "").toLowerCase();
  return OVERLOAD_MARKERS.some((marker) => lowered.includes(marker));
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

function annotateOpenAIOverloadDataLine(line) {
  if (!line.startsWith("data: ")) return { line, changed: false };
  let annotatedLine = line;
  let changed = false;
  try {
    const payload = JSON.parse(line.slice(6));
    if (appendRecoveryNoteToPayload(payload)) {
      annotatedLine = `data: ${JSON.stringify(payload)}`;
      changed = true;
    }
  } catch {
    // Not a JSON SSE payload; leave unchanged.
  }
  return { line: annotatedLine, changed };
}

export function annotateOpenAIOverloadText(text) {
  const raw = String(text || "");
  const lines = raw.split("\n");
  let changed = false;
  const annotated = lines.map((line) => {
    const result = annotateOpenAIOverloadDataLine(line);
    if (result.changed) changed = true;
    return result.line;
  }).join("\n");

  let result = changed ? annotated : raw;

  if (!changed) {
    try {
      const payload = JSON.parse(raw);
      if (appendRecoveryNoteToPayload(payload)) result = JSON.stringify(payload);
    } catch {
      // Not a standalone JSON payload; leave unchanged.
    }
  }
  return result;
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
