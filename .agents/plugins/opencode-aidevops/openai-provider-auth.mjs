/**
 * OpenAI provider OAuth pool runtime recovery.
 *
 * The built-in OpenAI provider does not pass through the Anthropic AuthHook,
 * so interactive sessions need a response-aware fetch guard that marks
 * usage-limited accounts and retries once with another pooled account.
 */

import { getAccounts, markAuthRefreshFailure, patchAccount, rotateOpenAIPoolToken } from "./oauth-pool.mjs";
import { OPENAI_TOKEN_ENDPOINT } from "./oauth-pool-constants.mjs";
import { annotateOpenAIOverloadResponse, formatRetryDelay, isOpenAIOverloadText, overloadRetryDelaysMs, sleep, wrapOpenAIOverloadStream } from "./openai-overload-retry.mjs";

export { isOpenAIOverloadText } from "./openai-overload-retry.mjs";

const OPENAI_API_HOST = "api.openai.com";
const OPENAI_API_PREFIX = "/v1/";
const DEFAULT_OPENAI_COOLDOWN_MS = 300_000;
const TOKEN_REFRESH_FAILURE_STATUSES = new Set([401, 403]);
const USAGE_LIMIT_MARKERS = [
  "usage limit",
  "rate limit",
  "too many requests",
  "quota",
  "insufficient_quota",
  "rate_limit_exceeded",
];

let installed = false;

export function parseRetryAfterMs(response) {
  const raw = response.headers?.get?.("retry-after");
  if (!raw) return DEFAULT_OPENAI_COOLDOWN_MS;
  const seconds = parseInt(raw, 10);
  if (Number.isFinite(seconds) && seconds > 0) return Math.max(seconds * 1000, DEFAULT_OPENAI_COOLDOWN_MS);
  const date = Date.parse(raw);
  if (Number.isFinite(date)) return Math.max(date - Date.now(), DEFAULT_OPENAI_COOLDOWN_MS);
  return DEFAULT_OPENAI_COOLDOWN_MS;
}

function requestUrl(input) {
  if (typeof input === "string") return input;
  if (input instanceof URL) return input.toString();
  return input?.url || "";
}

export function isOpenAIProviderRequest(input) {
  try {
    const url = new URL(requestUrl(input));
    return url.hostname === OPENAI_API_HOST && url.pathname.startsWith(OPENAI_API_PREFIX);
  } catch { return false; }
}

export function isOpenAITokenRefreshRequest(input) {
  try {
    const url = new URL(requestUrl(input));
    const endpoint = new URL(OPENAI_TOKEN_ENDPOINT);
    return url.origin === endpoint.origin && url.pathname === endpoint.pathname;
  } catch { return false; }
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

export async function isOpenAIOverloadResponse(response) {
  if (![500, 502, 503, 504, 529].includes(response.status)) return false;
  const payload = await readOpenAIErrorPayload(response);
  const error = payload?.error || payload;
  return isOpenAIOverloadText([error?.code, error?.type, error?.message].join(" "));
}

function headersFrom(input, init) {
  if (init?.headers) return new Headers(init.headers);
  if (typeof Request !== "undefined" && input instanceof Request) return new Headers(input.headers);
  return new Headers();
}

export function extractBearerToken(input, init) {
  const authorization = headersFrom(input, init).get("authorization") || "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : "";
}

export function resolveOpenAIAccount(accessToken) {
  const accounts = getAccounts("openai");
  if (accessToken) {
    const byAccess = accounts.find((account) => account.access === accessToken);
    if (byAccess) return byAccess;
  }
  return [...accounts].sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0] || null;
}

function isUnavailableAccount(account) {
  if (!account) return false;
  if (account.status === "auth-error") return true;
  return !!(account.cooldownUntil && account.cooldownUntil > Date.now());
}

function buildRetryRequest(input) {
  if (typeof Request !== "undefined" && input instanceof Request) return input.clone();
  return input;
}

function buildRetryInit(input, init, accessToken) {
  const retryInit = { ...(init || {}) };
  const retryHeaders = headersFrom(input, init);
  retryHeaders.set("authorization", `Bearer ${accessToken}`);
  retryInit.headers = retryHeaders;
  return retryInit;
}

async function readRequestBodyText(input, init) {
  try {
    if (typeof init?.body === "string") return init.body;
    if (init?.body instanceof URLSearchParams) return init.body.toString();
    if (typeof Request !== "undefined" && input instanceof Request) return await input.clone().text();
  } catch { /* best-effort: request body may be a non-cloneable stream */ }
  return "";
}

function extractOpenAIRefreshToken(bodyText) {
  try {
    const params = new URLSearchParams(bodyText);
    if (params.get("grant_type") !== "refresh_token") return "";
    return params.get("refresh_token") || "";
  } catch { return ""; }
}

function resolveOpenAIRefreshAccount(refreshToken) {
  if (!refreshToken) return null;
  return getAccounts("openai").find((account) => account.refresh === refreshToken) || null;
}

function buildOpenAITokenRefreshResponse(account) {
  const expiresAt = Number(account.expires) || Date.now() + 3600_000;
  const expiresIn = Math.max(1, Math.floor((expiresAt - Date.now()) / 1000));
  return new Response(JSON.stringify({
    access_token: account.access,
    refresh_token: account.refresh,
    expires_in: expiresIn,
    token_type: "Bearer",
  }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleOpenAITokenRefreshFailure(ctx) {
  const { client, response, refreshToken } = ctx;
  if (!TOKEN_REFRESH_FAILURE_STATUSES.has(response.status)) return response;
  const current = resolveOpenAIRefreshAccount(refreshToken);
  const currentEmail = current?.email || "unknown";
  if (current) markAuthRefreshFailure("openai", current);
  console.error(`[aidevops] OpenAI provider: token refresh failed (${response.status}) for ${currentEmail} — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return response;
  return buildOpenAITokenRefreshResponse(rotated);
}

async function handleOpenAIUsageLimit(ctx) {
  const { client, originalFetch, input, init, response, retryInput } = ctx;
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  const currentEmail = current?.email || "unknown";
  if (current) {
    patchAccount("openai", current.email, {
      status: "rate-limited",
      cooldownUntil: Date.now() + parseRetryAfterMs(response),
      lastUsed: new Date().toISOString(),
    });
  }
  console.error(`[aidevops] OpenAI provider: usage/rate limit for ${currentEmail} — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return response;
  const retryInit = buildRetryInit(input, init, rotated.access);
  return originalFetch(buildRetryRequest(retryInput), retryInit);
}

async function handleOpenAIOverload(ctx) {
  const { client, originalFetch, retryInput, init, response } = ctx;
  const retryDelays = overloadRetryDelaysMs();
  let lastResponse = response;
  for (let attempt = 0; attempt < retryDelays.length; attempt += 1) {
    const delayMs = retryDelays[attempt];
    await notifyOpenAIOverloadRetry(client, {
      attempt: attempt + 1,
      totalAttempts: retryDelays.length,
      delayMs,
      delayLabel: formatRetryDelay(delayMs),
    });
    if (delayMs > 0) await sleep(delayMs);
    lastResponse = await originalFetch(buildRetryRequest(retryInput), init);
    if (!(await isOpenAIOverloadResponse(lastResponse))) return lastResponse;
  }
  return annotateOpenAIOverloadResponse(lastResponse);
}

async function notifyOpenAIOverloadRetry(client, retry) {
  try {
    await client?.tui?.showToast?.({
      body: {
        title: "aidevops",
        message: `OpenAI overloaded. Retrying in ${retry.delayLabel} (${retry.attempt}/${retry.totalAttempts}). The session will attempt to continue automatically.`,
        variant: "warning",
        duration: Math.min(Math.max(retry.delayMs, 5_000), 30_000),
      },
    });
  } catch {
    // Toasts are advisory only; recovery must continue even if the TUI API is unavailable.
  }
}

async function maybeRotateBeforeOpenAIFetch(client, input, init) {
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  if (!isUnavailableAccount(current)) return init;
  const currentEmail = current?.email || "unknown";
  console.error(`[aidevops] OpenAI provider: current account ${currentEmail} unavailable before request — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return init;
  return buildRetryInit(input, init, rotated.access);
}

async function handleOpenAIFetchRequest(ctx) {
  const { client, originalFetch, input, init } = ctx;
  const openaiRequest = isOpenAIProviderRequest(input);
  const tokenRefreshRequest = isOpenAITokenRefreshRequest(input);
  const tokenRefreshBody = tokenRefreshRequest ? await readRequestBodyText(input, init) : "";
  const retryInput = openaiRequest ? buildRetryRequest(input) : input;
  const firstInit = openaiRequest ? await maybeRotateBeforeOpenAIFetch(client, input, init) : init;
  const response = await originalFetch(input, firstInit);

  if (tokenRefreshRequest) {
    return handleOpenAITokenRefreshFailure({
      client,
      response,
      refreshToken: extractOpenAIRefreshToken(tokenRefreshBody),
    });
  }
  if (!openaiRequest) return response;
  if (await isOpenAIUsageLimitResponse(response)) {
    return handleOpenAIUsageLimit({ client, originalFetch, input, init: firstInit, response, retryInput });
  }
  if (await isOpenAIOverloadResponse(response)) {
    return handleOpenAIOverload({ client, originalFetch, init: firstInit, response, retryInput });
  }
  if (response.ok) {
    return wrapOpenAIOverloadStream({
      originalFetch,
      response,
      retryInput,
      init: firstInit,
      buildRetryRequest,
      onRetry: (retry) => notifyOpenAIOverloadRetry(client, retry),
    });
  }
  return response;
}

export function installOpenAIProviderFetchRotation(client) {
  if (installed || typeof globalThis.fetch !== "function") return false;
  installed = true;
  const originalFetch = globalThis.fetch.bind(globalThis);
  globalThis.fetch = async (input, init) => {
    return handleOpenAIFetchRequest({ client, originalFetch, input, init });
  };
  return true;
}
