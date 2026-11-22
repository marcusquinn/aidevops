// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Shared HTTP transport helpers for GPT image requests.

import { redactProviderDetail } from "./gpt-image-sse.mjs";

export const MAX_API_RESPONSE_BYTES = 96 * 1024 * 1024;
const MAX_ERROR_RESPONSE_BYTES = 64 * 1024;
const IMAGE_REQUEST_TIMEOUT_MS = 180_000;
const TRANSPORT_CODES = new Set(["ECONNRESET", "ETIMEDOUT", "UND_ERR_SOCKET", "UND_ERR_CONNECT_TIMEOUT"]);

export const MODEL_SLUG = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/;

export function transportFailure(route, phase, cause, { started, response, signal }) {
  const elapsedMs = Math.min(IMAGE_REQUEST_TIMEOUT_MS, Math.max(0, Math.round(performance.now() - started)));
  const code = signal.aborted ? "timeout" :
    [cause?.code, cause?.cause?.code].find((value) => TRANSPORT_CODES.has(value)) || "unknown";
  const status = response ? ` status=${response.status}` : "";
  const error = new Error(`OpenAI image transport failure route=${route} phase=${phase} elapsed_ms=${elapsedMs}${status} code=${code}; provider outcome unconfirmed; do not automatically retry.`);
  error.code = "IMAGE_TRANSPORT_FAILURE";
  error.phase = phase;
  error.route = route;
  return error;
}

export async function fetchImageResponse(fetchImpl, endpoint, init, route, started) {
  try {
    return await fetchImpl(endpoint, init);
  } catch (error) {
    throw transportFailure(route, "request", error, { started, signal: init.signal });
  }
}

export async function withImageRequestTimeout(operation) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), IMAGE_REQUEST_TIMEOUT_MS);
  timer.unref?.();
  try {
    return await operation(controller.signal);
  } finally {
    clearTimeout(timer);
  }
}

export async function readBoundedJson(response, byteLimit, label, onReadError) {
  if (!response.body?.getReader) throw new Error(`${label} did not include a response body.`);
  const reader = response.body.getReader();
  const chunks = [];
  let totalBytes = 0;
  while (true) {
    let chunk;
    try {
      chunk = await reader.read();
    } catch (error) {
      if (onReadError) return onReadError(error);
      throw error;
    }
    const { done, value } = chunk;
    if (done) break;
    totalBytes += value.byteLength;
    if (totalBytes > byteLimit) {
      await reader.cancel().catch(() => {});
      throw new Error(`${label} exceeded the safe response limit.`);
    }
    chunks.push(Buffer.from(value));
  }
  return JSON.parse(Buffer.concat(chunks, totalBytes).toString("utf8"));
}

export async function imageRequestError(response, mode) {
  let code = "";
  let message = "";
  try {
    const payload = await readBoundedJson(response, MAX_ERROR_RESPONSE_BYTES, "OpenAI image error response");
    code = payload?.error?.code || payload?.error?.type || "";
    message = payload?.error?.message || "";
  } catch {
    message = "provider returned a non-JSON error";
  }
  const detail = [code, message].filter(Boolean).map(redactProviderDetail).join(": ");
  const error = new Error(`OpenAI ${mode} image request failed (${response.status})${detail ? `: ${detail}` : "."}`);
  error.code = code;
  error.status = response.status;
  return error;
}
