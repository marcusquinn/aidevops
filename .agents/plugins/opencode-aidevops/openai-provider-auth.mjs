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

import {
  applyOpenAIPoolAccount,
  forceRefreshOpenAIToken,
  getAccounts,
  markRejectedTokenFailure,
  patchAccount,
  rotateOpenAIPoolToken,
} from "./oauth-pool.mjs";
import { handleOpenAITokenRefreshFailure, isOpenAITokenRefreshRequest, readOpenAITokenRefreshBody } from "./openai-auth-refresh-recovery.mjs";
import {
  codexRequestCompressionEnabled,
  extendRequestInit,
  headersFrom,
  isOpenAIProviderRequest,
  logCodexRequestDiagnostic,
  prepareOpenAIRequest,
  responseRequestId,
  safeToken,
  zstdCompressorKind,
} from "./openai-codex-request.mjs";
import { parseRetryAfterValue } from "./provider-auth-pool-recovery.mjs";

export { isOpenAITokenRefreshRequest } from "./openai-auth-refresh-recovery.mjs";
export {
  codexRequestCompressionEnabled,
  compressCodexRequestBody,
  injectOpenAIIntentParameter,
  isCodexBackendRequest,
  isOpenAIProviderRequest,
  transformOpenAIRequestBody,
  zstdCompressorKind,
} from "./openai-codex-request.mjs";

const DEFAULT_OPENAI_COOLDOWN_MS = 300_000;
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

export function parseRetryAfterMs(response) {
  const raw = response.headers?.get?.("retry-after");
  const parsed = raw ? parseRetryAfterValue(raw) : null;
  return Math.max(parsed ?? DEFAULT_OPENAI_COOLDOWN_MS, DEFAULT_OPENAI_COOLDOWN_MS);
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
  if (!account) return false;
  if (account.status === "auth-error") return true;
  return Number(account.cooldownUntil) > Date.now();
}

function buildRetryRequest(input) {
  return typeof Request !== "undefined" && input instanceof Request ? input.clone() : input;
}

function buildRetryInit(input, init, account) {
  const retryHeaders = headersFrom(input, init);
  retryHeaders.set("authorization", `Bearer ${account.access}`);
  retryHeaders.delete("chatgpt-account-id");
  if (account.accountId) retryHeaders.set("chatgpt-account-id", account.accountId);
  return extendRequestInit(init, { headers: retryHeaders });
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
