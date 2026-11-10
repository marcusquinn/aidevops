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
import { activeLocalOnlyPolicy } from "./local-only-policy.mjs";
import {
  candidateRateLimitedUntil,
  routingFailoverTier,
  routingUnavailableDetail,
  selectSameTierFailoverCandidate,
} from "./model-routing.mjs";
import { resolveRoutingAvailability } from "./provider-rate-limits.mjs";
import { SPECIALIST_ADVISOR } from "./specialist-advisor.mjs";

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

async function transformedBody(request, provider, sessionID) {
  if (!requestBodyAllowed(request)) return undefined;
  // The V2 HTTP hook receives already-encoded bytes; decoding them as text is lossy.
  if (request.headers.get("content-encoding")) return undefined;
  const body = await request.clone().text().catch(() => null);
  if (body === null) return undefined;
  return provider === "anthropic"
    ? transformRequestBody(body, { sessionID })
    : transformOpenAIRequestBody(body);
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
  // Node requires duplex when forwarding the original ReadableStream body.
  else if (init.body) init.duplex = "half";
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
    process.env.AIDEVOPS_ANTHROPIC_API_KEY_SOURCE = "oauth-pool"; // GH#36707
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

function createHttpRequestHook(runtime) {
  return async function httpRequest(event) {
    const provider = event.model?.providerID;
    if (!SUPPORTED_PROVIDERS.has(provider) || runtime.listAccounts(provider).length === 0) return;
    const key = affinityKey(event);
    const skipEmail = runtime.retryState.get(key)?.email || "";
    const account = await runtime.selectAccount(provider, skipEmail);
    if (!account?.access) return;
    runtime.activateProvider(provider);
    const body = await transformedBody(event.request, provider, event.sessionID);
    event.request = provider === "anthropic"
      ? anthropicRequest(event.request, account.access, body)
      : openAIRequest(event.request, account, body);
    runtime.requestAccounts.set(event.request, account);
    runtime.retryState.delete(key);
    runtime.updateAccount(provider, account.email, {
      lastUsed: new Date().toISOString(),
      status: "active",
    });
  };
}

function createHttpResponseHook(runtime) {
  return async function httpResponse(event) {
    const provider = event.model?.providerID;
    if (!SUPPORTED_PROVIDERS.has(provider)) return;
    const key = affinityKey(event);
    const account = runtime.requestAccounts.get(event.request);
    if (!account) return;
    runtime.requestAccounts.delete(event.request);
    const usageLimited = provider === "openai"
      ? await isOpenAIUsageLimitResponse(event.response)
      : event.response.status === 429;
    const authFailed = provider === "openai"
      ? await isOpenAIAuthFailureResponse(event.response)
      : [401, 403].includes(event.response.status);
    if (usageLimited) {
      const cooldown = provider === "openai" ? parseRetryAfterMs(event.response) : cooldownFromResponse(event.response);
      runtime.updateAccount(provider, account.email, {
        status: "rate-limited",
        cooldownUntil: Date.now() + cooldown,
        lastUsed: new Date().toISOString(),
      });
      runtime.retryState.set(key, { email: account.email, delay: 0 });
    } else if (authFailed) {
      runtime.rejectAccount(provider, account);
      runtime.retryState.set(key, { email: account.email, delay: 0 });
    }
    if (provider === "anthropic") event.response = transformResponseStream(event.response);
  };
}

function createRetryHook(runtime) {
  return function retry(event) {
    const provider = event.model?.providerID;
    const state = runtime.retryState.get(affinityKey(event));
    if (!state || !SUPPORTED_PROVIDERS.has(provider)) return;
    const alternatives = runtime.listAccounts(provider).filter((account) => account.email !== state.email);
    if (alternatives.length === 0 || event.attempt > alternatives.length) return;
    event.decision = { retry: true, delay: state.delay };
  };
}

export function createV2ProviderAuthRuntime(dependencies = {}) {
  const runtime = {
    listAccounts: dependencies.getAccounts || getAccounts,
    selectAccount: dependencies.selectRuntimePoolAccount || selectRuntimePoolAccount,
    updateAccount: dependencies.patchAccount || patchAccount,
    rejectAccount: dependencies.markRejectedTokenFailure || markRejectedTokenFailure,
    activateProvider: dependencies.ensureProviderActivation || ensureProviderActivation,
    requestAccounts: new WeakMap(),
    retryState: new Map(),
  };

  for (const provider of SUPPORTED_PROVIDERS) {
    if (runtime.listAccounts(provider).length > 0) runtime.activateProvider(provider);
  }

  return {
    httpRequest: createHttpRequestHook(runtime),
    httpResponse: createHttpResponseHook(runtime),
    retry: createRetryHook(runtime),
  };
}

// GH#37667: agents whose model is the parent's exact route by design.
const PARENT_ROUTE_AGENTS = new Set([SPECIALIST_ADVISOR, "domain-focused", "domain-light"]);
const MAX_FAILOVER_SESSIONS = 64;

function routingModelKey(model) {
  const id = model?.id || model?.modelID;
  return model?.providerID && id ? `${model.providerID}/${id}` : "";
}

// Host APIs return either the record or a `{ data }` envelope.
function unwrapRecord(result) {
  return result && typeof result === "object" && "data" in result ? result.data : result;
}

function modelList(result) {
  const value = unwrapRecord(result);
  return Array.isArray(value) ? value : [];
}

async function inheritedChildRoute(deps, event, current) {
  const session = unwrapRecord(await deps.getSession({ sessionID: event.sessionID }));
  if (!session?.parentID) return "root_session";
  const agentID = session.agent || event.agent || "";
  if (!agentID || PARENT_ROUTE_AGENTS.has(agentID)) return "parent_route_agent";
  const agent = unwrapRecord(await deps.getAgent({ agentID }));
  if (!agent) return "agent_unknown";
  if (agent.model) return "pinned_agent";
  const routed = deps.switched.get(event.sessionID);
  if (routed) return routed.candidate === current ? "" : "pinned_model";
  // A child not on its parent's model was spawned with an explicit model.
  const parent = unwrapRecord(await deps.getSession({ sessionID: session.parentID }));
  return routingModelKey(parent?.model) === current ? "" : "pinned_model";
}

function rememberFailover(switched, sessionID, state) {
  switched.delete(sessionID);
  switched.set(sessionID, state);
  while (switched.size > MAX_FAILOVER_SESSIONS) switched.delete(switched.keys().next().value);
}

/**
 * GH#37667: move a running Task child off a provider whose OAuth pool is fully
 * rate limited. OpenCode V2 reloads the session model before every retry
 * attempt (SessionRunner.runStep → SessionContext.load → resolveModel), so
 * switching the child session's model inside the `retry` hook makes the next
 * attempt run on the next routable same-tier model within the same Task run;
 * the parent receives that child's normal result. Nothing is cancelled: when
 * no candidate qualifies, the host's own retry decision stands.
 * @returns {(event: object) => Promise<boolean>} true when the child switched
 */
export function createV2SubagentRateLimitFailover({
  getSession,
  getAgent,
  listModels,
  switchModel,
  routing,
  resolvePolicy = activeLocalOnlyPolicy,
  resolveAvailability = resolveRoutingAvailability,
  log = () => {},
  now = Date.now,
} = {}) {
  const deps = { getSession, getAgent, switched: new Map() };
  return async function subagentRateLimitFailover(event) {
    // Only a retry the host already scheduled; a terminal decision stays terminal.
    if (event?.decision?.retry !== true || !routing || !event.sessionID) return false;
    const current = routingModelKey(event.model);
    const availability = resolveAvailability();
    // API-key providers and partially limited pools are never reported here.
    if (!current || !candidateRateLimitedUntil(current, availability, now())) return false;
    if (resolvePolicy()?.bound) return false;
    try {
      const skip = await inheritedChildRoute(deps, event, current);
      if (skip) return false;
      // A repeated failover keeps the tier of the first one.
      const tier = deps.switched.get(event.sessionID)?.tier
        || routingFailoverTier(routing, current, event.model.variant || "");
      if (!tier) return false;
      const next = selectSameTierFailoverCandidate(routing, tier, {
        exclude: [current],
        available: modelList(await listModels()),
        availability,
        policy: resolvePolicy(),
        now: now(),
      });
      if (!next) {
        log("WARN", `[aidevops] Subagent rate-limit failover found no routable '${tier}' model for session ${event.sessionID}${routingUnavailableDetail(routing, tier, availability)}`);
        return false;
      }
      await switchModel({ sessionID: event.sessionID, model: next.model });
      rememberFailover(deps.switched, event.sessionID, { candidate: next.candidate, tier });
      event.decision = { retry: true, delay: 0 };
      log("INFO", `[aidevops] Subagent rate-limit failover: session ${event.sessionID} ${current} -> ${next.candidate} ('${tier}' tier)`);
      return true;
    } catch (error) {
      log("WARN", `[aidevops] Subagent rate-limit failover skipped: ${error?.message || error}`);
      return false;
    }
  };
}
