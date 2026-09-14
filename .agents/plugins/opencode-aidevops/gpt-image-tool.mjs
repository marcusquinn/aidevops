// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  markOAuthImageRateLimit,
  markOAuthImageSuccess,
  resolveGptImageAuth,
  rotateOAuthImageAccount,
} from "./gpt-image-auth.mjs";
import { readReferenceImages, saveGeneratedImage, validateImageOutputPath } from "./gpt-image-io.mjs";
import {
  API_IMAGE_MODELS,
  DEFAULT_API_IMAGE_MODEL,
  requestApiImage,
  requestOAuthImage,
} from "./gpt-image-request.mjs";
import { resolveGptImageProjectRoot } from "./gpt-image-worktree.mjs";

const IMAGE_QUALITIES = new Set(["low", "medium", "high", "auto"]);
const IMAGE_FORMATS = new Set(["png", "jpeg", "webp"]);
const API_IMAGE_MODEL_SET = new Set(API_IMAGE_MODELS);

function validateOutputArgs(args) {
  if (typeof args.prompt !== "string" || typeof args.out !== "string") {
    throw new Error("Image prompt and output path must be strings.");
  }
  if (args.quality !== undefined && !IMAGE_QUALITIES.has(args.quality)) throw new Error("Unsupported image quality.");
  if (args.format !== undefined && !IMAGE_FORMATS.has(args.format)) throw new Error("Unsupported image format.");
  if (args.size !== undefined && typeof args.size !== "string") throw new Error("Image size must be a string.");
  if (args.workdir !== undefined && typeof args.workdir !== "string") throw new Error("Image workdir must be a string.");
}

function validateReferenceArgs(args) {
  if (args.images !== undefined && (!Array.isArray(args.images) || args.images.some((path) => typeof path !== "string"))) {
    throw new Error("Reference images must be an array of path strings.");
  }
}

function validateAuthArgs(args) {
  if (args.auth !== undefined && !["oauth", "api"].includes(args.auth)) throw new Error("Image auth must be oauth or api.");
  if (args.account !== undefined && typeof args.account !== "string") throw new Error("Image account must be a string.");
  if (args.model !== undefined && (typeof args.model !== "string" || !API_IMAGE_MODEL_SET.has(args.model))) {
    throw new Error("Unsupported API image model.");
  }
  if (args.model !== undefined && args.auth !== "api") {
    throw new Error("Image model selection requires explicit auth=api because OAuth model selection is unavailable.");
  }
}

function validateRawArgs(args) {
  if (!args || typeof args !== "object" || Array.isArray(args)) throw new Error("Image tool arguments must be an object.");
  validateOutputArgs(args);
  validateReferenceArgs(args);
  validateAuthArgs(args);
}

function validatePrompt(value) {
  const prompt = String(value || "").trim();
  if (!prompt || prompt.length > 32_000) {
    throw new Error("Image prompt must contain 1-32,000 characters.");
  }
  return prompt;
}

function validateSize(value) {
  const size = value || "auto";
  if (size === "auto") return size;
  const match = /^(\d+)x(\d+)$/.exec(size);
  if (!match) throw new Error("Image size must be auto or WIDTHxHEIGHT.");
  const width = Number(match[1]);
  const height = Number(match[2]);
  const longEdge = Math.max(width, height);
  const shortEdge = Math.min(width, height);
  const pixels = width * height;
  const aligned = width % 16 === 0 && height % 16 === 0;
  const boundedEdges = longEdge <= 3840 && longEdge / shortEdge <= 3;
  const boundedPixels = pixels >= 655_360 && pixels <= 8_294_400;
  if (!aligned || !boundedEdges || !boundedPixels) {
    throw new Error("Image size violates GPT Image 2 dimension constraints.");
  }
  return size;
}

async function requestWithOAuth(auth, args, images, options) {
  let result = await requestOAuthImage(auth, args, images, options.fetchImpl);
  if (result.response.status !== 429) return { auth, result };

  (options.markOAuthRateLimit || markOAuthImageRateLimit)(auth, result.response);
  if (auth.pinned) return { auth, result };
  const rotated = await rotateOAuthImageAccount(auth, options);
  if (!rotated) return { auth, result };
  await result.response.body?.cancel?.().catch(() => {});
  result = await requestOAuthImage(rotated, args, images, options.fetchImpl);
  if (result.response.status === 429) {
    (options.markOAuthRateLimit || markOAuthImageRateLimit)(rotated, result.response);
  }
  return { auth: rotated, result };
}

function billingLabel(mode) {
  return mode === "oauth" ? "ChatGPT subscription OAuth" : "OpenAI Platform API";
}

async function executeImageGeneration(rawArgs, options, context) {
  validateRawArgs(rawArgs);
  const args = {
    ...rawArgs,
    prompt: validatePrompt(rawArgs.prompt),
    size: validateSize(rawArgs.size),
    quality: rawArgs.quality || "auto",
    format: rawArgs.format || "png",
  };
  const project = await resolveGptImageProjectRoot(args.workdir, options.projectRoot, context, options);
  await validateImageOutputPath(args.out, project.root, args.format);
  const images = await readReferenceImages(args.images, project.root);
  let auth = await resolveGptImageAuth(args, options);
  let result;

  if (auth.mode === "oauth") {
    ({ auth, result } = await requestWithOAuth(auth, args, images, options));
  } else {
    args.model ||= DEFAULT_API_IMAGE_MODEL;
    result = await requestApiImage(auth, args, images, options.fetchImpl);
  }
  if (!result.response.ok) throw result.error;

  const saved = await saveGeneratedImage(args.out, project.root, result.base64, args.format, {
    requestedSize: args.size,
    scriptsDir: options.scriptsDir,
    spawnImpl: options.imageWriterSpawn,
  });
  if (auth.mode === "oauth") (options.markOAuthSuccess || markOAuthImageSuccess)(auth);
  const versionNote = saved.versioned ? " Existing output was preserved with a versioned filename." : "";
  const cleanupNote = saved.cleanupWarning ? " Temporary-file cleanup reported a filesystem warning." : "";
  const rootNote = project.linked ? " in the validated session-owned linked worktree" : "";
  const dimensions = `${saved.width}x${saved.height}`;
  const requestedModel = result.requestedModel || "provider-managed";
  const providerModel = result.providerModel || "unknown";
  return `Generated image saved to ${saved.projectPath}${rootNote}. Requested size: ${args.size}; native dimensions: ${dimensions}. Billing route: ${billingLabel(auth.mode)}. Requested image model: ${requestedModel}; provider-confirmed image model: ${providerModel}.${versionNote}${cleanupNote}`;
}

export function createGptImageTool(tool, z, options = {}) {
  const fetchImpl = options.fetchImpl || globalThis.fetch?.bind(globalThis);
  if (typeof fetchImpl !== "function") throw new Error("GPT image generation requires fetch support.");
  const executionOptions = { ...options, fetchImpl, projectRoot: options.projectRoot || process.cwd() };
  return tool({
    description:
      "Generate or reference-edit a PNG, JPEG, or WebP with OpenAI image generation. ChatGPT OAuth uses a provider-managed image model by default; API billing and API image-model selection must be explicit. Writes only inside the OpenCode project or a validated session-owned linked worktree and never overwrites an existing image.",
    args: {
      prompt: z.string().describe("Description of the image to generate or edit."),
      out: z.string().describe("Project-relative output path with an extension matching format."),
      format: z.enum(["png", "jpeg", "webp"]).optional().describe("Native output format; defaults to png."),
      quality: z.enum(["low", "medium", "high", "auto"]).optional().describe("OpenAI image quality; defaults to auto."),
      size: z.string().optional().describe("auto or WIDTHxHEIGHT satisfying supported OpenAI image constraints."),
      workdir: z.string().optional().describe("Optional absolute path to the current session-owned linked worktree."),
      images: z.array(z.string()).optional().describe("Optional project-relative PNG, JPEG, or WebP reference image paths."),
      auth: z.enum(["oauth", "api"]).optional().describe("Billing route; defaults to ChatGPT OAuth. API must be explicit."),
      account: z.string().optional().describe("OAuth pool email when auth=oauth, or named API-key alias when auth=api."),
      model: z.enum(API_IMAGE_MODELS).optional().describe("API-only image model; defaults to gpt-image-2 when auth=api."),
    },
    async execute(args, context) {
      return executeImageGeneration(args && typeof args === "object" ? args : {}, executionOptions, context);
    },
  });
}
