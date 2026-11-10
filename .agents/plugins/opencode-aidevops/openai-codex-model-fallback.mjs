// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Hosted-image routing uses this ChatGPT/Codex-supported slug. Workload/API
// aliases are not evidence of subscription availability.
export const CODEX_FALLBACK_MODEL = "gpt-6-sol";

export async function codexFallbackBody(input, init) {
  // Lazy loading keeps the image router independent of provider hook startup.
  const { isCodexBackendRequest } = await import("./openai-codex-request.mjs");
  if (!isCodexBackendRequest(input)) return null;
  try {
    const body = init?.body ?? (input instanceof Request ? await input.clone().text() : null);
    if (typeof body !== "string") return null;
    const parsed = JSON.parse(body);
    return typeof parsed.model === "string" ? parsed : null;
  } catch {
    return null;
  }
}

async function isModelRejection(response) {
  if (![400, 404].includes(response.status)) return false;
  try {
    const payload = await response.clone().json();
    const error = payload?.error || payload;
    return error?.code === "model_not_found"
      || String(error?.message || error?.detail || "").includes("is not supported when using Codex with a ChatGPT account");
  } catch {
    return false;
  }
}

// Record a definite pre-generation model rejection for the request's OpenAI
// auth and return the original response unchanged. Same-tier failover happens
// at routing level (GH#36698), never by swapping in a hardcoded slug here.
// SSE, transport, auth, quota and policy failures are neither recorded nor retried.
export async function recordCodexModelRejection(response, input, init) {
  const { headersFrom, isCodexBackendRequest, safeToken } = await import("./openai-codex-request.mjs");
  if (!isCodexBackendRequest(input) || !await isModelRejection(response)) return response;
  // Read and parse the original body only after a definite model rejection.
  const original = await codexFallbackBody(input, init);
  if (!original) return response;
  const { authSignatureFromHeaders, markModelUnavailable } = await import("./model-unavailability.mjs");
  markModelUnavailable(`openai/${original.model}`, authSignatureFromHeaders(headersFrom(input, init)));
  // t18957: move an auto-routed compaction model off the rejected model.
  try {
    const { rerouteCompactionAfterRejection } = await import("./compaction-routing.mjs");
    rerouteCompactionAfterRejection(`openai/${original.model}`);
  } catch {
    // Best effort: a reroute failure must not break the rejected response path.
  }
  console.error(`[aidevops] OpenAI provider: model unavailable for current auth requested=openai/${safeToken(original.model)}`);
  return response;
}
