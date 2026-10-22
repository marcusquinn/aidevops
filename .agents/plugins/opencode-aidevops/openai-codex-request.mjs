// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OpenAI/Codex request classification, intent-schema transform, zstd body
 * compression and metadata-only request diagnostics (GH#34414, GH#34562).
 * Extracted from openai-provider-auth.mjs, which re-exports the public API.
 */

import * as zlib from "node:zlib";

import { injectIntentSchemaProperty } from "./provider-auth-body.mjs";

const OPENAI_API_HOST = "api.openai.com";
const OPENAI_API_PREFIX = "/v1/";
const OPENAI_CODEX_HOST = "chatgpt.com";
const OPENAI_CODEX_PREFIX = "/backend-api/codex/";
const COMPRESSION_DISABLED_VALUES = new Set(["0", "false", "off", "no"]);
const CODEX_UNCOMPRESSED_LIMIT_BYTES = 1_048_576;
const RESPONSE_REQUEST_ID_HEADERS = ["x-request-id", "request-id", "cf-ray"];

function transformOpenAITool(tool) {
  if (tool?.type !== "function") return tool;
  const owner = tool.function?.parameters ? tool.function : (tool.parameters ? tool : null);
  if (!owner) return tool;
  const parameters = injectIntentSchemaProperty(owner.parameters);
  if (parameters === owner.parameters) return tool;
  return owner === tool
    ? { ...tool, parameters }
    : { ...tool, function: { ...tool.function, parameters } };
}

/** Inject intent into OpenAI Responses and Chat Completions function schemas. */
export function injectOpenAIIntentParameter(tools) {
  return tools.map(transformOpenAITool);
}

/** Transform a serialized OpenAI request body without retaining its contents. */
export function transformOpenAIRequestBody(body) {
  if (!body || typeof body !== "string") return body;
  try {
    const parsed = JSON.parse(body);
    if (!Array.isArray(parsed.tools)) return body;
    parsed.tools = injectOpenAIIntentParameter(parsed.tools);
    return JSON.stringify(parsed);
  } catch {
    return body;
  }
}

function parseRequestUrl(input) {
  const rawUrl = typeof input === "string" || input instanceof URL ? input.toString() : input?.url;
  return URL.parse(rawUrl);
}

/** True for ChatGPT Codex backend requests (OAuth), not the Platform API. */
export function isCodexBackendRequest(input) {
  const url = parseRequestUrl(input);
  return Boolean(url && url.hostname === OPENAI_CODEX_HOST && url.pathname.startsWith(OPENAI_CODEX_PREFIX));
}

export function isOpenAIProviderRequest(input) {
  const url = parseRequestUrl(input);
  return Boolean(url && (
    (url.hostname === OPENAI_API_HOST && url.pathname.startsWith(OPENAI_API_PREFIX))
    || isCodexBackendRequest(input)
  ));
}

/** `AIDEVOPS_CODEX_REQUEST_COMPRESSION=0|false|off|no` disables compression for diagnosis. */
export function codexRequestCompressionEnabled(env = process.env) {
  const raw = String(env.AIDEVOPS_CODEX_REQUEST_COMPRESSION ?? "").trim().toLowerCase();
  return !COMPRESSION_DISABLED_VALUES.has(raw);
}

/** Which zstd implementation this runtime provides: `bun`, `node`, or `none`. */
export function zstdCompressorKind() {
  if (typeof globalThis.Bun?.zstdCompressSync === "function") return "bun";
  if (typeof zlib.zstdCompressSync === "function") return "node";
  return "none";
}

function resolveZstdCompressor() {
  const kind = zstdCompressorKind();
  if (kind === "bun") return (data) => globalThis.Bun.zstdCompressSync(data);
  if (kind === "node") return (data) => zlib.zstdCompressSync(data);
  return null;
}

/**
 * zstd-compress a serialized request body. Returns null when the runtime lacks
 * zstd or compression fails, so callers send the original body unchanged.
 */
export function compressCodexRequestBody(body, compress = resolveZstdCompressor()) {
  if (!compress || typeof body !== "string" || !body) return null;
  try {
    const compressed = compress(Buffer.from(body, "utf8"));
    return compressed instanceof Uint8Array && compressed.byteLength > 0 ? compressed : null;
  } catch {
    return null;
  }
}

export function headersFrom(input, init) {
  const requestHeaders = typeof Request !== "undefined" && input instanceof Request ? input.headers : undefined;
  return new Headers(init?.headers ?? requestHeaders);
}

export function extendRequestInit(init, overrides) {
  if (init == null) return { ...overrides };
  return Object.assign(Object.create(Object(init)), overrides);
}

/** Ordered reasons a Codex body is sent uncompressed (GH#34562). */
const CODEX_COMPRESSION_SKIP_CHECKS = [
  ["not-codex", ({ input }) => !isCodexBackendRequest(input)],
  ["empty", ({ body }) => !body],
  ["disabled", () => !codexRequestCompressionEnabled()],
  ["preencoded", ({ headers }) => headers.has("content-encoding")],
  ["no-compressor", ({ compress }) => !compress],
];

/** Compression metadata for a Codex request; null for other routes (GH#34562). */
function codexCompressionDecision(input, reason, originalBytes = null, encodedBytes = originalBytes) {
  if (!isCodexBackendRequest(input)) return null;
  return { reason, original_bytes: originalBytes, encoded_bytes: encodedBytes };
}

export async function prepareOpenAIRequest(input, init) {
  const initHasBody = init != null && "body" in Object(init);
  if (initHasBody && typeof init.body !== "string") {
    return { input, init, compression: codexCompressionDecision(input, "non-string-body") };
  }
  let body = initHasBody ? init.body : "";
  if (!initHasBody && typeof Request !== "undefined" && input instanceof Request) {
    body = await input.clone().text().catch(() => null);
  }
  if (body === null) return { input, init, compression: codexCompressionDecision(input, "unreadable-body") };
  const transformedBody = transformOpenAIRequestBody(body);
  const encoded = encodeCodexRequestInit(input, init, transformedBody);
  if (encoded.init) return { input, init: encoded.init, compression: encoded.compression };
  if (!body || transformedBody === body) return { input, init, compression: encoded.compression };
  return { input, init: extendRequestInit(init, { body: transformedBody }), compression: encoded.compression };
}

/**
 * Build an init carrying the zstd-compressed body and `content-encoding: zstd`
 * for Codex backend requests. Retries reuse this init, so every attempt sends
 * the same encoded bytes. `init` is null to leave the request uncompressed;
 * `compression` records why (GH#34562).
 */
function encodeCodexRequestInit(input, init, body) {
  const bytes = typeof body === "string" ? Buffer.byteLength(body, "utf8") : null;
  const headers = headersFrom(input, init);
  const compress = resolveZstdCompressor();
  const skipped = CODEX_COMPRESSION_SKIP_CHECKS.find(([, check]) => check({ input, body, headers, compress }));
  const compressed = skipped ? null : compressCodexRequestBody(body, compress);
  if (!compressed) {
    return { init: null, compression: codexCompressionDecision(input, skipped?.[0] ?? "compress-failed", bytes) };
  }
  headers.set("content-encoding", "zstd");
  headers.delete("content-length");
  return {
    init: extendRequestInit(init, { body: compressed, headers }),
    compression: codexCompressionDecision(input, "applied", bytes, compressed.byteLength),
  };
}

/** Restrict a diagnostic token to a short safe charset; anything else is dropped. */
export function safeToken(value, fallback = "none") {
  const text = String(value ?? "").trim();
  return /^[A-Za-z0-9._:+-]{1,128}$/.test(text) ? text : fallback;
}

export function responseRequestId(response) {
  const headers = response?.headers;
  if (typeof headers?.get !== "function") return "";
  for (const name of RESPONSE_REQUEST_ID_HEADERS) {
    const value = headers.get(name);
    if (value) return value;
  }
  return "";
}

function codexEndpoint(input) {
  const url = parseRequestUrl(input);
  const segment = url ? url.pathname.slice(OPENAI_CODEX_PREFIX.length).split("/", 1)[0] : "";
  return /^[a-z0-9_-]{1,32}$/.test(segment) ? segment : "other";
}

function shouldLogCodexRequest(compression, attempts) {
  if (process.env.AIDEVOPS_PLUGIN_DEBUG === "1") return true;
  const failed = attempts.some((attempt) => attempt.status === "fetch-error" || attempt.status >= 500);
  const oversizeUncompressed = compression.reason !== "applied"
    && (compression.original_bytes ?? 0) > CODEX_UNCOMPRESSED_LIMIT_BYTES;
  return failed || oversizeUncompressed;
}

/** GH#34562: metadata-only Codex request line; never bodies, headers, URLs or accounts. */
export function logCodexRequestDiagnostic(compression, ctx) {
  try {
    if (!compression || !shouldLogCodexRequest(compression, ctx.attempts)) return;
    const last = ctx.attempts.at(-1) || {};
    const fields = [
      `endpoint=${codexEndpoint(ctx.input)}`,
      `reason=${compression.reason}`,
      `original_bytes=${compression.original_bytes ?? "unknown"}`,
      `encoded_bytes=${compression.encoded_bytes ?? "unknown"}`,
      `encoding=${safeToken(headersFrom(ctx.input, ctx.init).get("content-encoding"), "identity")}`,
      `compressor=${zstdCompressorKind()}`,
      `attempts=${ctx.attempts.map((attempt) => `${attempt.kind}:${attempt.status}`).join(",") || "none"}`,
      `request_id=${safeToken(last.requestId)}`,
    ];
    if (last.error) fields.push(`error=${safeToken(last.error, "other")}`);
    console.error(`[aidevops] OpenAI provider: codex request ${fields.join(" ")}`);
  } catch {
    // Diagnostics must never change the request outcome.
  }
}
