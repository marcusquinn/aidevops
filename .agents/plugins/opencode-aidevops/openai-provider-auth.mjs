/**
 * OpenAI provider OAuth pool runtime recovery.
 *
 * The built-in OpenAI provider does not pass through the Anthropic AuthHook,
 * so interactive sessions need a response-aware fetch guard that marks
 * usage-limited accounts and retries once with another pooled account.
 */

import { getAccounts, patchAccount, rotateOpenAIPoolToken } from "./oauth-pool.mjs";

const OPENAI_API_HOST = "api.openai.com";
const OPENAI_API_PREFIX = "/v1/";
const DEFAULT_OPENAI_COOLDOWN_MS = 300_000;
const DEFAULT_OVERLOAD_RETRY_DELAYS_MS = [2_000, 5_000, 10_000];
const OVERLOAD_MARKERS = [
  "service_unavailable_error",
  "server_is_overloaded",
  "servers are currently overloaded",
];
const STREAM_CONTENT_MARKERS = [
  "response.output_text.delta",
  "response.function_call_arguments.delta",
  "response.code_interpreter_call_code.delta",
  "response.reasoning_summary_text.delta",
];
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

function overloadRetryDelaysMs() {
  const raw = process.env.AIDEVOPS_OPENAI_OVERLOAD_RETRY_DELAYS_MS || "";
  const parsed = raw
    .split(",")
    .map((part) => Number.parseInt(part.trim(), 10))
    .filter((value) => Number.isFinite(value) && value >= 0);
  return parsed.length > 0 ? parsed : DEFAULT_OVERLOAD_RETRY_DELAYS_MS;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function isOpenAIOverloadText(text) {
  const lowered = String(text || "").toLowerCase();
  return OVERLOAD_MARKERS.some((marker) => lowered.includes(marker));
}

function isOpenAIStreamContentText(text) {
  return STREAM_CONTENT_MARKERS.some((marker) => String(text || "").includes(marker));
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
  return originalFetch(retryInput, retryInit);
}

async function handleOpenAIOverload(ctx) {
  const { originalFetch, retryInput, init, response } = ctx;
  const retryDelays = overloadRetryDelaysMs();
  let lastResponse = response;
  for (const delayMs of retryDelays) {
    if (delayMs > 0) await sleep(delayMs);
    lastResponse = await originalFetch(buildRetryRequest(retryInput), init);
    if (!(await isOpenAIOverloadResponse(lastResponse))) return lastResponse;
  }
  return lastResponse;
}

function enqueueChunks(controller, chunks) {
  for (const chunk of chunks) controller.enqueue(chunk);
}

async function pipeRemainingStream(reader, controller) {
  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      controller.close();
      return;
    }
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

    const text = decoder.decode(value, { stream: true });
    buffered.push(value);
    bufferedText += text;

    if (isOpenAIOverloadText(bufferedText)) {
      if (retryAvailable) {
        await reader.cancel().catch(() => {});
        return "retry";
      }
      enqueueChunks(controller, buffered);
      return "pipe";
    }

    if (isOpenAIStreamContentText(bufferedText) || bufferedText.length > 65_536) {
      enqueueChunks(controller, buffered);
      return "pipe";
    }
  }
}

async function retryOpenAIOverloadStream(ctx) {
  const { originalFetch, response, retryInput, init, controller, retryDelays } = ctx;
  const decoder = new TextDecoder();
  let currentResponse = response;

  for (let attempt = 0; ; attempt += 1) {
    const reader = currentResponse.body.getReader();
    const outcome = await inspectStreamPrefix(reader, controller, decoder, attempt < retryDelays.length);
    if (outcome === "closed") return;
    if (outcome === "pipe") return pipeRemainingStream(reader, controller);

    const delayMs = retryDelays[attempt];
    console.error(`[aidevops] OpenAI provider: overloaded stream error — retrying request (${attempt + 1}/${retryDelays.length})`);
    if (delayMs > 0) await sleep(delayMs);
    currentResponse = await originalFetch(buildRetryRequest(retryInput), init);
    if (!currentResponse.body) {
      controller.close();
      return;
    }
  }
}

function wrapOpenAIOverloadStream(ctx) {
  const { originalFetch, response, retryInput, init } = ctx;
  if (!response.body) return response;
  const contentType = response.headers?.get?.("content-type") || "";
  if (!contentType.includes("text/event-stream")) return response;

  const retryDelays = overloadRetryDelaysMs();

  const stream = new ReadableStream({
    async start(controller) {
      try {
        await retryOpenAIOverloadStream({ originalFetch, response, retryInput, init, controller, retryDelays });
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

async function maybeRotateBeforeOpenAIFetch(client, input, init) {
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  if (!isUnavailableAccount(current)) return init;
  const currentEmail = current?.email || "unknown";
  console.error(`[aidevops] OpenAI provider: current account ${currentEmail} unavailable before request — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return init;
  return buildRetryInit(input, init, rotated.access);
}

export function installOpenAIProviderFetchRotation(client) {
  if (installed || typeof globalThis.fetch !== "function") return false;
  installed = true;
  const originalFetch = globalThis.fetch.bind(globalThis);
  globalThis.fetch = async (input, init) => {
    const openaiRequest = isOpenAIProviderRequest(input);
    const retryInput = openaiRequest ? buildRetryRequest(input) : input;
    const firstInit = openaiRequest ? await maybeRotateBeforeOpenAIFetch(client, input, init) : init;
    const response = await originalFetch(input, firstInit);
    if (!openaiRequest) return response;
    if (await isOpenAIUsageLimitResponse(response)) {
      return handleOpenAIUsageLimit({ client, originalFetch, input, init: firstInit, response, retryInput });
    }
    if (await isOpenAIOverloadResponse(response)) {
      return handleOpenAIOverload({ originalFetch, init: firstInit, response, retryInput });
    }
    if (response.ok) {
      return wrapOpenAIOverloadStream({ originalFetch, response, retryInput, init: firstInit });
    }
    return response;
  };
  return true;
}
