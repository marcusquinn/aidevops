// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// OAuth request semantics were independently implemented after reviewing the
// MIT-licensed opencode-gpt-imagegen project by Yuji Hatakeyama:
// https://github.com/yuji-hatakeyama/opencode-gpt-imagegen

const CODEX_RESPONSES_ENDPOINT = "https://chatgpt.com/backend-api/codex/responses";
const CODEX_MODELS_ENDPOINT = "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0";
const OPENAI_IMAGES_GENERATE_ENDPOINT = "https://api.openai.com/v1/images/generations";
const OPENAI_IMAGES_EDIT_ENDPOINT = "https://api.openai.com/v1/images/edits";
import { parseImageSse, redactProviderDetail } from "./gpt-image-sse.mjs";
import { CODEX_FALLBACK_MODEL } from "./openai-codex-model-fallback.mjs";

export { parseImageSse };
export const DEFAULT_API_IMAGE_MODEL = "gpt-image-2";
export const API_IMAGE_MODELS = Object.freeze([
  "gpt-image-2",
  "gpt-image-2.5-flare",
  "gpt-image-2.5-sunburst",
]);

const MAX_API_RESPONSE_BYTES = 96 * 1024 * 1024;
const MAX_ERROR_RESPONSE_BYTES = 64 * 1024;
const IMAGE_REQUEST_TIMEOUT_MS = 180_000;
const TRANSPORT_CODES = new Set(["ECONNRESET", "ETIMEDOUT", "UND_ERR_SOCKET", "UND_ERR_CONNECT_TIMEOUT"]);

function transportFailure(route, phase, cause, { started, response, signal }) {
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

async function fetchImageResponse(fetchImpl, endpoint, init, route, started) {
  try {
    return await fetchImpl(endpoint, init);
  } catch (error) {
    throw transportFailure(route, "request", error, { started, signal: init.signal });
  }
}

async function withImageRequestTimeout(operation) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), IMAGE_REQUEST_TIMEOUT_MS);
  timer.unref?.();
  try {
    return await operation(controller.signal);
  } finally {
    clearTimeout(timer);
  }
}

function imageToolArgs(args) {
  return {
    type: "image_generation",
    output_format: args.format || "png",
    quality: args.quality || "auto",
    ...(args.size && args.size !== "auto" ? { size: args.size } : {}),
  };
}

function oauthRequestBody(args, images, model) {
  const content = [{ type: "input_text", text: args.prompt }];
  for (const image of images) content.push({ type: "input_image", image_url: image.dataUrl });
  return {
    model,
    instructions: "Generate the requested image by invoking the image_generation tool exactly once.",
    input: [{ role: "user", content }],
    tools: [imageToolArgs(args)],
    tool_choice: { type: "image_generation" },
    stream: true,
    store: false,
  };
}

function oauthHeaders(auth) {
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${auth.accessToken}`,
    ...(auth.accountId ? { "ChatGPT-Account-Id": auth.accountId } : {}),
    originator: "opencode",
    Accept: "text/event-stream",
  };
}

const MAX_ROUTER_CANDIDATES = 3;
const MODEL_SLUG = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/;

export const NO_IMAGE_ENTITLEMENT_MESSAGE =
  "This ChatGPT account has no image-capable Codex model: the backend does not expose the image_generation tool for any model it lists. Use auth=\"openrouter\" or auth=\"api\" (explicit billing routes) instead.";

function isImageToolStripped(error) {
  return /Tool choice 'image_generation' not found/i.test(String(error?.message || ""));
}

// Live Codex model slugs for this account (best effort; [] on any failure).
async function listCodexModels(auth, fetchImpl, signal) {
  try {
    const response = await fetchImpl(CODEX_MODELS_ENDPOINT, {
      method: "GET",
      headers: { ...oauthHeaders(auth), Accept: "application/json" },
      signal,
    });
    if (!response?.ok) return [];
    const payload = await response.json();
    const entries = Array.isArray(payload?.models) ? payload.models : Array.isArray(payload?.data) ? payload.data : [];
    return entries
      .map((entry) => (typeof entry === "string" ? entry : entry?.slug || entry?.id))
      .filter((slug) => typeof slug === "string" && MODEL_SLUG.test(slug));
  } catch {
    return [];
  }
}

async function attemptOAuthRouter(auth, args, images, model, ctx) {
  const { fetchImpl, signal, started } = ctx;
  const response = await fetchImageResponse(fetchImpl, CODEX_RESPONSES_ENDPOINT, {
    method: "POST",
    headers: oauthHeaders(auth),
    body: JSON.stringify(oauthRequestBody(args, images, model)),
    signal,
  }, "oauth", started);
  if (!response.ok) return { response, base64: "", error: await imageRequestError(response, "oauth") };
  return {
    response,
    base64: await parseImageSse(response.body, (error) => {
      throw transportFailure("oauth", "response-body", error, { started, response, signal });
    }),
    routerModel: model,
    requestedModel: null,
    providerModel: null,
  };
}

export async function requestOAuthImage(auth, args, images, fetchImpl) {
  return withImageRequestTimeout(async (signal) => {
    const ctx = { fetchImpl, signal, started: performance.now() };
    let result = await attemptOAuthRouter(auth, args, images, CODEX_FALLBACK_MODEL, ctx);
    const rejected = result.error?.code === "model_not_found";
    if (!rejected) {
      if (isImageToolStripped(result.error)) result.error = entitlementError(result.error);
      return result;
    }
    // The hardcoded router slug is not available to this account: try the
    // account's live Codex models (bounded), never a guessed slug.
    const candidates = (await listCodexModels(auth, fetchImpl, signal))
      .filter((slug) => slug !== CODEX_FALLBACK_MODEL)
      .slice(0, MAX_ROUTER_CANDIDATES);
    let stripped = false;
    for (const model of candidates) {
      const next = await attemptOAuthRouter(auth, args, images, model, ctx);
      if (next.response.ok) return next;
      if (isImageToolStripped(next.error)) {
        stripped = true;
        continue;
      }
      if (next.error?.code === "model_not_found") continue;
      return next;
    }
    if (stripped) result.error = entitlementError(result.error);
    return result;
  });
}

function entitlementError(cause) {
  const error = new Error(NO_IMAGE_ENTITLEMENT_MESSAGE);
  error.code = "no_image_entitlement";
  error.status = cause?.status || 400;
  return error;
}

const OPENROUTER_IMAGES_ENDPOINT = "https://openrouter.ai/api/v1/images";
export const DEFAULT_OPENROUTER_IMAGE_MODEL = "openai/gpt-image-2.6-sunburst";

export async function requestOpenRouterImage(auth, args, fetchImpl) {
  return withImageRequestTimeout(async (signal) => {
    const started = performance.now();
    const requestedModel = DEFAULT_OPENROUTER_IMAGE_MODEL;
    const body = {
      model: requestedModel,
      prompt: args.prompt,
      quality: args.quality || "auto",
      size: args.size || "auto",
      output_format: args.format || "png",
    };
    const response = await fetchImageResponse(fetchImpl, OPENROUTER_IMAGES_ENDPOINT, {
      method: "POST",
      headers: { Authorization: `Bearer ${auth.accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal,
    }, "openrouter", started);
    if (!response.ok) return { response, base64: "", error: await imageRequestError(response, "openrouter") };
    const payload = await readBoundedJson(response, MAX_API_RESPONSE_BYTES, "OpenRouter image response", (error) => {
      throw transportFailure("openrouter", "response-body", error, { started, response, signal });
    });
    const base64 = payload?.data?.[0]?.b64_json;
    if (typeof base64 !== "string" || !base64) throw new Error("OpenRouter image response did not contain an image.");
    const responseModel = payload?.model;
    const providerModel = typeof responseModel === "string" && MODEL_SLUG.test(responseModel.replace("/", "-")) ? responseModel : null;
    return { response, base64, requestedModel, providerModel };
  });
}

function apiJsonBody(args) {
  return {
    model: args.model,
    prompt: args.prompt,
    quality: args.quality || "auto",
    size: args.size || "auto",
    output_format: args.format || "png",
  };
}

function apiMultipartBody(args, images) {
  const body = new FormData();
  body.append("model", args.model);
  body.append("prompt", args.prompt);
  body.append("quality", args.quality || "auto");
  body.append("size", args.size || "auto");
  body.append("output_format", args.format || "png");
  for (const image of images) {
    body.append("image[]", new Blob([image.buffer], { type: image.mime }), image.name);
  }
  return body;
}

function apiRequest(auth, args, images, signal) {
  const headers = { Authorization: `Bearer ${auth.accessToken}` };
  if (images.length === 0) {
    headers["Content-Type"] = "application/json";
    return {
      endpoint: OPENAI_IMAGES_GENERATE_ENDPOINT,
      init: { method: "POST", headers, body: JSON.stringify(apiJsonBody(args)), signal },
    };
  }
  return {
    endpoint: OPENAI_IMAGES_EDIT_ENDPOINT,
    init: { method: "POST", headers, body: apiMultipartBody(args, images), signal },
  };
}

async function readBoundedJson(response, byteLimit, label, onReadError) {
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

export async function requestApiImage(auth, args, images, fetchImpl) {
  return withImageRequestTimeout(async (signal) => {
    const started = performance.now();
    const requestedModel = args.model || DEFAULT_API_IMAGE_MODEL;
    const request = apiRequest(auth, { ...args, model: requestedModel }, images, signal);
    const response = await fetchImageResponse(fetchImpl, request.endpoint, request.init, "api", started);
    if (!response.ok) return { response, base64: "", error: await imageRequestError(response, "api") };
    const contentLength = Number(response.headers.get("content-length") || 0);
    if (contentLength > MAX_API_RESPONSE_BYTES) {
      await response.body?.cancel?.().catch(() => {});
      throw new Error("OpenAI Images API response exceeded the safe response limit.");
    }
    const payload = await readBoundedJson(response, MAX_API_RESPONSE_BYTES, "OpenAI Images API response", (error) => {
      throw transportFailure("api", "response-body", error, { started, response, signal });
    });
    const base64 = payload?.data?.[0]?.b64_json;
    if (typeof base64 !== "string" || !base64) throw new Error("OpenAI Images API response did not contain an image.");
    const responseModel = payload?.model;
    const providerModel =
      typeof responseModel === "string" && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/.test(responseModel)
        ? responseModel
        : null;
    return { response, base64, requestedModel, providerModel };
  });
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
