// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// OAuth request semantics were independently implemented after reviewing the
// MIT-licensed opencode-gpt-imagegen project by Yuji Hatakeyama:
// https://github.com/yuji-hatakeyama/opencode-gpt-imagegen

const CODEX_RESPONSES_ENDPOINT = "https://chatgpt.com/backend-api/codex/responses";
const CODEX_MODELS_ENDPOINT = "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0";
const OPENAI_IMAGES_GENERATE_ENDPOINT = "https://api.openai.com/v1/images/generations";
const OPENAI_IMAGES_EDIT_ENDPOINT = "https://api.openai.com/v1/images/edits";
import { parseImageSse } from "./gpt-image-sse.mjs";
import {
  MAX_API_RESPONSE_BYTES,
  MODEL_SLUG,
  fetchImageResponse,
  imageRequestError,
  readBoundedJson,
  transportFailure,
  withImageRequestTimeout,
} from "./gpt-image-http.mjs";
import { CODEX_FALLBACK_MODEL } from "./openai-codex-model-fallback.mjs";

export { parseImageSse, imageRequestError };
export const DEFAULT_API_IMAGE_MODEL = "gpt-image-2";
export const API_IMAGE_MODELS = Object.freeze([
  "gpt-image-2",
  "gpt-image-2.5-flare",
  "gpt-image-2.5-sunburst",
]);

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

export const NO_COMPATIBLE_IMAGE_MODEL_MESSAGE =
  "No compatible image-capable Codex model was found among the attempted candidates; this bounded probe does not establish account-wide image entitlement. Use auth=\"openrouter\" or auth=\"api\" (explicit billing routes) instead.";

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
  let base64;
  try {
    base64 = await parseImageSse(response.body, (error) => {
      throw transportFailure("oauth", "response-body", error, { started, response, signal });
    });
  } catch (error) {
    if (error?.code !== "model_not_found" && !isImageToolStripped(error)) throw error;
    return { response, base64: "", error };
  }
  return {
    response,
    base64,
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
      if (isImageToolStripped(result.error)) result.error = compatibilityError(result.error);
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
      if (next.response.ok && !next.error) return next;
      if (isImageToolStripped(next.error)) {
        stripped = true;
        continue;
      }
      if (next.error?.code === "model_not_found") continue;
      return next;
    }
    if (stripped) result.error = compatibilityError(result.error);
    return result;
  });
}

function compatibilityError(cause) {
  const error = new Error(NO_COMPATIBLE_IMAGE_MODEL_MESSAGE);
  error.code = "no_compatible_image_model";
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
