/**
 * OpenAI provider OAuth pool runtime recovery.
 *
 * The built-in OpenAI provider does not pass through the Anthropic AuthHook,
 * so interactive sessions need a response-aware fetch guard that marks
 * usage-limited accounts and retries once with another pooled account.
 *
 * The same guard zstd-compresses ChatGPT Codex backend request bodies (GH#34414).
 * The backend rejects uncompressed bodies above 1 MiB with an HTTP 503
 * "upstream connect error"; upstream Codex CLI compresses these requests by
 * default (`enable_request_compression`), OpenCode's built-in provider does not.
 *
 * Metadata-only diagnostics (GH#34562) go to the plugin log
 * (~/.aidevops/logs/opencode-plugin.log), never the TUI:
 * - once per process: `fetch guard installed` with loaded version and compressor;
 * - per Codex request, only on a 5xx/fetch error or an uncompressed body above
 *   1 MiB (every request with AIDEVOPS_PLUGIN_DEBUG=1): `codex request` with the
 *   compression reason, byte counts, encoding, attempt statuses and response
 *   request id. Never bodies, headers, URLs, tokens or account identities.
 * Reading a failed turn: no `fetch guard installed` line from that process means
 * pre-GH#34562 code was loaded; no `codex request` line means the request never
 * reached this guard (e.g. OPENCODE_EXPERIMENTAL_WEBSOCKETS transport);
 * `reason=applied` with a small `encoded_bytes` points away from the size limit.
 */

import * as zlib from "node:zlib";

import {
  applyOpenAIPoolAccount,
  forceRefreshOpenAIToken,
  getAccounts,
  markRejectedTokenFailure,
  patchAccount,
  rotateOpenAIPoolToken,
} from "./oauth-pool.mjs";
import { handleOpenAITokenRefreshFailure, isOpenAITokenRefreshRequest, readOpenAITokenRefreshBody } from "./openai-auth-refresh-recovery.mjs";
import { injectIntentSchemaProperty } from "./provider-auth-body.mjs";
import { parseRetryAfterValue } from "./provider-auth-pool-recovery.mjs";

export { isOpenAITokenRefreshRequest } from "./openai-auth-refresh-recovery.mjs";

const OPENAI_API_HOST = "api.openai.com";
const OPENAI_API_PREFIX = "/v1/";
const OPENAI_CODEX_HOST = "chatgpt.com";
const OPENAI_CODEX_PREFIX = "/backend-api/codex/";
const DEFAULT_OPENAI_COOLDOWN_MS = 300_000;
const COMPRESSION_DISABLED_VALUES = new Set(["0", "false", "off", "no"]);
const CODEX_UNCOMPRESSED_LIMIT_BYTES = 1_048_576;
const RESPONSE_REQUEST_ID_HEADERS = ["x-request-id", "request-id", "cf-ray"];
const USAGE_LIMIT_MARKERS = [
  "usage limit",
  "rate limit",
  "too many requests",
  "quota",
  "insufficient_quota",
  "rate_limit_exceeded",
];
const AUTH_FAILURE_MARKERS = [
  "authentication token is expired",
  "access token has expired",
  "expired token",
  "expired access token",
  "invalid access token",
  "invalid token",
  "invalid_api_key",
  "invalid_token",
  "sign in again",
  "token_expired",
  "unauthorized",
];

let installed = false;

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

export function parseRetryAfterMs(response) {
  const raw = response.headers?.get?.("retry-after");
  const parsed = raw ? parseRetryAfterValue(raw) : null;
  return Math.max(parsed ?? DEFAULT_OPENAI_COOLDOWN_MS, DEFAULT_OPENAI_COOLDOWN_MS);
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

async function readOpenAIErrorPayload(response) {
  try {
    const cloned = response.clone();
    const contentType = cloned.headers?.get?.("content-type") || "";
    if (contentType.includes("application/json")) return await cloned.json();
    return { error: { message: await cloned.text() } };
  } catch { return null; }
}

export async function isOpenAIUsageLimitResponse(response) {
  if (response.status === 429) return true;
  if (![400, 403].includes(response.status)) return false;
  const payload = await readOpenAIErrorPayload(response);
  const error = payload?.error || payload;
  const code = String(error?.code || error?.type || "").toLowerCase();
  const message = String(error?.message || "").toLowerCase();
  return [code, message].some((text) => USAGE_LIMIT_MARKERS.some((marker) => text.includes(marker)));
}

export async function isOpenAIAuthFailureResponse(response) {
  if (response.status === 401) return true;
  if (response.status !== 403 || await isOpenAIUsageLimitResponse(response)) return false;
  const payload = await readOpenAIErrorPayload(response);
  const error = payload?.error || payload;
  const code = String(error?.code || error?.type || "").toLowerCase();
  const message = String(error?.message || error?.detail || payload?.detail || error || "").toLowerCase();
  return [code, message].some((text) => AUTH_FAILURE_MARKERS.some((marker) => text.includes(marker)));
}

function headersFrom(input, init) {
  const requestHeaders = typeof Request !== "undefined" && input instanceof Request ? input.headers : undefined;
  return new Headers(init?.headers ?? requestHeaders);
}

export function extractBearerToken(input, init) {
  const authorization = headersFrom(input, init).get("authorization") || "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : "";
}

export function resolveOpenAIAccount(accessToken) {
  const accounts = getAccounts("openai");
  if (accessToken) return accounts.find((account) => account.access === accessToken) ?? null;
  return [...accounts].sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0] ?? null;
}

function isUnavailableAccount(account) {
  return Boolean(account && (
    account.status === "auth-error"
    || (account.cooldownUntil && account.cooldownUntil > Date.now())
  ));
}

function buildRetryRequest(input) {
  return typeof Request !== "undefined" && input instanceof Request ? input.clone() : input;
}

function extendRequestInit(init, overrides) {
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

async function prepareOpenAIRequest(input, init) {
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

function buildRetryInit(input, init, account) {
  const retryHeaders = headersFrom(input, init);
  retryHeaders.set("authorization", `Bearer ${account.access}`);
  retryHeaders.delete("chatgpt-account-id");
  if (account.accountId) retryHeaders.set("chatgpt-account-id", account.accountId);
  return extendRequestInit(init, { headers: retryHeaders });
}

/** Restrict a diagnostic token to a short safe charset; anything else is dropped. */
function safeToken(value, fallback = "none") {
  const text = String(value ?? "").trim();
  return /^[A-Za-z0-9._:+-]{1,128}$/.test(text) ? text : fallback;
}

function responseRequestId(response) {
  const headers = response?.headers;
  if (typeof headers?.get !== "function") return "";
  for (const name of RESPONSE_REQUEST_ID_HEADERS) {
    const value = headers.get(name);
    if (value) return value;
  }
  return "";
}

/** Send one attempt and append `{ kind, status, requestId|error }` metadata. */
async function recordAttempt(attempts, kind, send) {
  try {
    const response = await send();
    attempts.push({ kind, status: response.status, requestId: responseRequestId(response) });
    return response;
  } catch (error) {
    const aborted = error?.name === "AbortError";
    attempts.push({
      kind,
      status: aborted ? "aborted" : "fetch-error",
      error: error?.cause?.code || error?.code || error?.name,
    });
    throw error;
  }
}

function retryOpenAIRequest(ctx, account, kind) {
  const retryInit = buildRetryInit(ctx.input, ctx.init, account);
  return recordAttempt(ctx.attempts, kind, () => ctx.originalFetch(buildRetryRequest(ctx.retryInput), retryInit));
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
function logCodexRequestDiagnostic(compression, ctx) {
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

async function handleOpenAIUsageLimit(ctx) {
  const { client, input, init, response } = ctx;
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  if (!current) return response;
  const currentEmail = current?.email || "unknown";
  patchAccount("openai", current.email, {
    status: "rate-limited",
    cooldownUntil: Date.now() + parseRetryAfterMs(response),
    lastUsed: new Date().toISOString(),
  });
  console.error(`[aidevops] OpenAI provider: usage/rate limit for ${currentEmail} — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return response;
  return retryOpenAIRequest(ctx, rotated, "usage-rotate");
}

async function handleOpenAIAuthFailure(ctx) {
  const { client, input, init, response } = ctx;
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  if (!current) return response;
  const currentEmail = current?.email || "unknown";
  const requestAccountId = headersFrom(input, init).get("chatgpt-account-id");
  if (!current.accountId && requestAccountId) {
    current.accountId = requestAccountId;
    patchAccount("openai", current.email, { accountId: requestAccountId });
  }
  console.error(`[aidevops] OpenAI provider: rejected token for ${currentEmail} — forcing one refresh`);
  const refreshedAccess = await forceRefreshOpenAIToken(current);
  if (refreshedAccess) {
    await applyOpenAIPoolAccount(client, current);
    const retryResponse = await retryOpenAIRequest(ctx, current, "auth-refresh");
    if (await isOpenAIAuthFailureResponse(retryResponse)) {
      markRejectedTokenFailure("openai", current);
    }
    return retryResponse;
  }
  console.error(`[aidevops] OpenAI provider: refresh unavailable for ${currentEmail} — trying another pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return response;
  const retryResponse = await retryOpenAIRequest(ctx, rotated, "auth-rotate");
  if (await isOpenAIAuthFailureResponse(retryResponse)) {
    markRejectedTokenFailure("openai", rotated);
  }
  return retryResponse;
}

async function maybeRotateBeforeOpenAIFetch(client, input, init) {
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  if (!isUnavailableAccount(current)) return init;
  const currentEmail = current?.email || "unknown";
  console.error(`[aidevops] OpenAI provider: current account ${currentEmail} unavailable before request — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return init;
  return buildRetryInit(input, init, rotated);
}

async function handleOpenAIProviderFetch({ client, originalFetch, input, init }) {
  const prepared = await prepareOpenAIRequest(input, init);
  const retryInput = buildRetryRequest(prepared.input);
  const firstInit = await maybeRotateBeforeOpenAIFetch(client, prepared.input, prepared.init);
  const ctx = { client, originalFetch, input: prepared.input, init: firstInit, retryInput, attempts: [] };
  const firstKind = firstInit === prepared.init ? "initial" : "preflight-rotate";
  try {
    ctx.response = await recordAttempt(ctx.attempts, firstKind, () => originalFetch(prepared.input, firstInit));
    if (await isOpenAIUsageLimitResponse(ctx.response)) return await handleOpenAIUsageLimit(ctx);
    if (await isOpenAIAuthFailureResponse(ctx.response)) return await handleOpenAIAuthFailure(ctx);
    return ctx.response;
  } finally {
    logCodexRequestDiagnostic(prepared.compression, ctx);
  }
}

async function handleOpenAIFetchRequest(ctx) {
  const { client, originalFetch, input, init } = ctx;
  if (isOpenAITokenRefreshRequest(input)) {
    const bodyText = await readOpenAITokenRefreshBody(input, init);
    const response = await originalFetch(input, init);
    return handleOpenAITokenRefreshFailure({ client, response, bodyText });
  }
  if (isOpenAIProviderRequest(input)) return handleOpenAIProviderFetch(ctx);
  return originalFetch(input, init);
}

/** GH#34562: one line per process proving which guard revision is loaded. */
function logFetchGuardInstalled(version) {
  const runtime = process.versions?.bun ? `bun-${process.versions.bun}` : `node-${process.versions?.node}`;
  const compression = codexRequestCompressionEnabled() ? "enabled" : "disabled";
  console.error(
    `[aidevops] OpenAI provider: fetch guard installed version=${safeToken(version, "unknown")} `
    + `runtime=${safeToken(runtime, "unknown")} zstd=${zstdCompressorKind()} codex_compression=${compression}`,
  );
}

export function installOpenAIProviderFetchRotation(client, { version = "" } = {}) {
  if (installed || typeof globalThis.fetch !== "function") return false;
  installed = true;
  const originalFetch = globalThis.fetch.bind(globalThis);
  globalThis.fetch = async (input, init) => {
    return handleOpenAIFetchRequest({ client, originalFetch, input, init });
  };
  logFetchGuardInstalled(version);
  return true;
}
