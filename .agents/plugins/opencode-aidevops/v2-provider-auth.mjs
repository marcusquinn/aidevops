// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  getAccounts,
  markRejectedTokenFailure,
  patchAccount,
  selectRuntimePoolAccount,
} from "./oauth-pool.mjs";
import {
  addBetaQueryParam,
  buildRequestHeaders,
  transformRequestBody,
  transformResponseStream,
} from "./provider-auth-request.mjs";
import {
  isOpenAIAuthFailureResponse,
  isOpenAIUsageLimitResponse,
  parseRetryAfterMs,
  transformOpenAIRequestBody,
} from "./openai-provider-auth.mjs";

const SUPPORTED_PROVIDERS = new Set(["anthropic", "openai"]);
const DEFAULT_COOLDOWN_MS = 300_000;

function affinityKey(event) {
  return [
    event.sessionID || "",
    event.kind || "primary",
    event.agent || "",
    event.model?.providerID || "",
    event.model?.id || event.model?.modelID || "",
  ].join(":");
}

function requestBodyAllowed(request) {
  return !["GET", "HEAD"].includes(request.method.toUpperCase());
}

async function transformedBody(request, provider) {
  if (!requestBodyAllowed(request)) return undefined;
  const body = await request.clone().text().catch(() => null);
  if (body === null) return undefined;
  return provider === "anthropic" ? transformRequestBody(body) : transformOpenAIRequestBody(body);
}

function rebuildRequest(request, url, headers, body) {
  const init = {
    method: request.method,
    headers,
    redirect: request.redirect,
    signal: request.signal,
  };
  if (requestBodyAllowed(request)) init.body = body ?? request.body;
  if (typeof init.body === "string") headers.delete("content-length");
  return new Request(url, init);
}

function anthropicRequest(request, accessToken, body) {
  const headers = buildRequestHeaders(request, {}, accessToken);
  const betaRequest = addBetaQueryParam(request);
  const url = betaRequest instanceof Request ? betaRequest.url : betaRequest.toString();
  return rebuildRequest(request, url, headers, body);
}

function openAIRequest(request, account, body) {
  const headers = new Headers(request.headers);
  headers.set("authorization", `Bearer ${account.access}`);
  headers.delete("chatgpt-account-id");
  if (account.accountId) headers.set("chatgpt-account-id", account.accountId);
  return rebuildRequest(request, request.url, headers, body);
}

function ensureProviderActivation(provider) {
  if (provider === "anthropic" && !process.env.ANTHROPIC_API_KEY) {
    process.env.ANTHROPIC_API_KEY = "aidevops-oauth-pool";
  }
  if (provider === "openai" && !process.env.OPENAI_API_KEY) {
    process.env.OPENAI_API_KEY = "aidevops-oauth-pool";
    process.env.AIDEVOPS_OPENAI_API_KEY_SOURCE = "oauth-pool";
  }
}

function cooldownFromResponse(response) {
  const retryAfter = response.headers.get("retry-after");
  if (!retryAfter) return DEFAULT_COOLDOWN_MS;
  const seconds = Number(retryAfter);
  if (Number.isFinite(seconds)) return Math.max(seconds * 1000, DEFAULT_COOLDOWN_MS);
  const date = Date.parse(retryAfter);
  return Number.isFinite(date) ? Math.max(date - Date.now(), DEFAULT_COOLDOWN_MS) : DEFAULT_COOLDOWN_MS;
}

export function createV2ProviderAuthRuntime(dependencies = {}) {
  const listAccounts = dependencies.getAccounts || getAccounts;
  const selectAccount = dependencies.selectRuntimePoolAccount || selectRuntimePoolAccount;
  const updateAccount = dependencies.patchAccount || patchAccount;
  const rejectAccount = dependencies.markRejectedTokenFailure || markRejectedTokenFailure;
  const activateProvider = dependencies.ensureProviderActivation || ensureProviderActivation;
  const requestAccounts = new WeakMap();
  const retryState = new Map();

  for (const provider of SUPPORTED_PROVIDERS) {
    if (listAccounts(provider).length > 0) activateProvider(provider);
  }

  async function httpRequest(event) {
    const provider = event.model?.providerID;
    if (!SUPPORTED_PROVIDERS.has(provider) || listAccounts(provider).length === 0) return;
    const key = affinityKey(event);
    const skipEmail = retryState.get(key)?.email || "";
    const account = await selectAccount(provider, skipEmail);
    if (!account?.access) return;
    activateProvider(provider);
    const body = await transformedBody(event.request, provider);
    event.request = provider === "anthropic"
      ? anthropicRequest(event.request, account.access, body)
      : openAIRequest(event.request, account, body);
    requestAccounts.set(event.request, account);
    retryState.delete(key);
    updateAccount(provider, account.email, {
      lastUsed: new Date().toISOString(),
      status: "active",
    });
  }

  async function httpResponse(event) {
    const provider = event.model?.providerID;
    if (!SUPPORTED_PROVIDERS.has(provider)) return;
    const key = affinityKey(event);
    const account = requestAccounts.get(event.request);
    if (!account) return;
    requestAccounts.delete(event.request);
    const usageLimited = provider === "openai"
      ? await isOpenAIUsageLimitResponse(event.response)
      : event.response.status === 429;
    const authFailed = provider === "openai"
      ? await isOpenAIAuthFailureResponse(event.response)
      : [401, 403].includes(event.response.status);
    if (usageLimited) {
      const cooldown = provider === "openai" ? parseRetryAfterMs(event.response) : cooldownFromResponse(event.response);
      updateAccount(provider, account.email, {
        status: "rate-limited",
        cooldownUntil: Date.now() + cooldown,
        lastUsed: new Date().toISOString(),
      });
      retryState.set(key, { email: account.email, delay: 0 });
    } else if (authFailed) {
      rejectAccount(provider, account);
      retryState.set(key, { email: account.email, delay: 0 });
    }
    if (provider === "anthropic") event.response = transformResponseStream(event.response);
  }

  function retry(event) {
    const provider = event.model?.providerID;
    const state = retryState.get(affinityKey(event));
    if (!state || !SUPPORTED_PROVIDERS.has(provider)) return;
    const alternatives = listAccounts(provider).filter((account) => account.email !== state.email);
    if (alternatives.length === 0 || event.attempt > alternatives.length) return;
    event.decision = { retry: true, delay: state.delay };
  }

  return { httpRequest, httpResponse, retry };
}
