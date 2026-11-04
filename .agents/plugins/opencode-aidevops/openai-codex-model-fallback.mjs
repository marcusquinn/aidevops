// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// ChatGPT/Codex-supported slug, independently live-verified in GH#36600.
// Workload/API aliases are not evidence of subscription availability.
export const CODEX_FALLBACK_MODEL = "gpt-6-sol";

export async function codexFallbackBody(input, init) {
  // Lazy loading keeps the image router independent of provider hook startup.
  const { isCodexBackendRequest } = await import("./openai-codex-request.mjs");
  if (!isCodexBackendRequest(input)) return null;
  try {
    const body = init?.body ?? (input instanceof Request ? await input.clone().text() : null);
    if (typeof body !== "string") return null;
    const parsed = JSON.parse(body);
    if (typeof parsed.model !== "string" || parsed.model === CODEX_FALLBACK_MODEL) return null;
    return { ...parsed, model: CODEX_FALLBACK_MODEL };
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

// Retry only a definite pre-generation model rejection, once, on the same
// endpoint/account. Never retry SSE, transport, auth, quota or policy failures.
export async function retryCodexModelRejection(response, input, init, send) {
  const { extendRequestInit, headersFrom, isCodexBackendRequest, prepareOpenAIRequest, safeToken } = await import("./openai-codex-request.mjs");
  if (!isCodexBackendRequest(input) || !await isModelRejection(response)) return response;
  // Read and parse the original body only after a definite model rejection.
  const body = await codexFallbackBody(input, init);
  if (!body) return response;
  const headers = headersFrom(input, init);
  headers.delete("content-encoding");
  headers.delete("content-length");
  const retry = await prepareOpenAIRequest(input, extendRequestInit(init, { body: JSON.stringify(body), headers }));
  console.error(`[aidevops] OpenAI provider: Codex model_not_found; retrying once with ChatGPT-supported model=${safeToken(body.model)}`);
  return send(retry.input, retry.init);
}
