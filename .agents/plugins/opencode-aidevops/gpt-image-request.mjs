// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// OAuth request semantics were independently implemented after reviewing the
// MIT-licensed opencode-gpt-imagegen project by Yuji Hatakeyama:
// https://github.com/yuji-hatakeyama/opencode-gpt-imagegen

const CODEX_RESPONSES_ENDPOINT = "https://chatgpt.com/backend-api/codex/responses";
const OPENAI_IMAGES_GENERATE_ENDPOINT = "https://api.openai.com/v1/images/generations";
const OPENAI_IMAGES_EDIT_ENDPOINT = "https://api.openai.com/v1/images/edits";
import { readFileSync } from "node:fs";
import { parseImageSse, redactProviderDetail } from "./gpt-image-sse.mjs";

export { parseImageSse };

const MODEL_ROUTING_TABLE = new URL("../../configs/model-routing-table.json", import.meta.url);
const MAX_API_RESPONSE_BYTES = 96 * 1024 * 1024;
const MAX_ERROR_RESPONSE_BYTES = 64 * 1024;
const IMAGE_REQUEST_TIMEOUT_MS = 180_000;

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

function subscriptionRouterModels() {
  const routing = JSON.parse(readFileSync(MODEL_ROUTING_TABLE, "utf8"));
  const models = ["thinking", "standard", "simple"]
    .flatMap((tier) => routing.tiers?.[tier]?.models || [])
    .filter((model) => model.startsWith("openai/"))
    .map((model) => model.slice("openai/".length));
  return [...new Set(models)].slice(0, 2);
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

export async function requestOAuthImage(auth, args, images, fetchImpl) {
  const models = subscriptionRouterModels();
  if (models.length === 0) throw new Error("No OpenAI subscription router model is configured.");
  return withImageRequestTimeout(async (signal) => {
    let result;
    for (const model of models) {
      const response = await fetchImpl(CODEX_RESPONSES_ENDPOINT, {
        method: "POST",
        headers: oauthHeaders(auth),
        body: JSON.stringify(oauthRequestBody(args, images, model)),
        signal,
      });
      if (response.ok) return { response, base64: await parseImageSse(response.body) };
      result = { response, base64: "", error: await imageRequestError(response, "oauth") };
      if (result.error.code !== "model_not_found") return result;
    }
    return result;
  });
}

function apiJsonBody(args) {
  return {
    model: "gpt-image-2",
    prompt: args.prompt,
    quality: args.quality || "auto",
    size: args.size || "auto",
    output_format: args.format || "png",
  };
}

function apiMultipartBody(args, images) {
  const body = new FormData();
  body.append("model", "gpt-image-2");
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

async function readBoundedJson(response, byteLimit, label) {
  if (!response.body?.getReader) throw new Error(`${label} did not include a response body.`);
  const reader = response.body.getReader();
  const chunks = [];
  let totalBytes = 0;
  while (true) {
    const { done, value } = await reader.read();
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
    const request = apiRequest(auth, args, images, signal);
    const response = await fetchImpl(request.endpoint, request.init);
    if (!response.ok) return { response, base64: "", error: await imageRequestError(response, "api") };
    const contentLength = Number(response.headers.get("content-length") || 0);
    if (contentLength > MAX_API_RESPONSE_BYTES) {
      await response.body?.cancel?.().catch(() => {});
      throw new Error("OpenAI Images API response exceeded the safe response limit.");
    }
    const payload = await readBoundedJson(response, MAX_API_RESPONSE_BYTES, "OpenAI Images API response");
    const base64 = payload?.data?.[0]?.b64_json;
    if (typeof base64 !== "string" || !base64) throw new Error("OpenAI Images API response did not contain an image.");
    return { response, base64 };
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
