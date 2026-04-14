/**
 * Google proxy config helpers: model discovery, provider registration, config persistence.
 * Extracted from google-proxy.mjs to keep that file's complexity below the threshold.
 */

import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { homedir } from "os";

const GOOGLE_API_BASE = "https://generativelanguage.googleapis.com";
const OPENCODE_CONFIG_PATH = join(homedir(), ".config", "opencode", "opencode.json");

// ---------------------------------------------------------------------------
// Model discovery
// ---------------------------------------------------------------------------

/**
 * Discover available Gemini models from the Google Generative AI API.
 * @param {string} accessToken - Valid OAuth access token
 * @returns {Promise<Array<{ id: string, name: string, contextWindow: number, maxTokens: number }>>}
 */
export async function discoverGoogleModels(accessToken) {
  const models = [];
  try {
    const resp = await fetch(`${GOOGLE_API_BASE}/v1beta/models`, {
      headers: { "Authorization": `Bearer ${accessToken}` },
    });
    if (!resp.ok) {
      console.error(`[aidevops] Google proxy: model discovery failed: HTTP ${resp.status}`);
      return models;
    }
    const data = await resp.json();
    if (!data.models || !Array.isArray(data.models)) return models;
    for (const model of data.models) {
      const methods = model.supportedGenerationMethods || [];
      if (!methods.includes("generateContent")) continue;
      const modelId = model.name?.replace(/^models\//, "") || "";
      if (!modelId) continue;
      if (modelId.includes("embedding") || modelId.includes("aqa") || modelId.includes("imagen")) continue;
      models.push({
        id: modelId,
        name: model.displayName || modelId,
        contextWindow: model.inputTokenLimit || 1048576,
        maxTokens: model.outputTokenLimit || 65536,
      });
    }
    console.error(`[aidevops] Google proxy: discovered ${models.length} models`);
  } catch (err) {
    console.error(`[aidevops] Google proxy: model discovery error: ${err.message}`);
  }
  return models;
}

/**
 * Build OpenCode provider model entries from discovered Google models.
 * @param {Array<{ id: string, name: string, contextWindow?: number, maxTokens?: number }>} models
 * @returns {Record<string, object>}
 */
export function buildGoogleProviderModels(models) {
  const entries = {};
  for (const model of models) {
    entries[model.id] = {
      name: model.name,
      attachment: true,
      tool_call: true,
      temperature: true,
      reasoning: model.id.includes("thinking") || false,
      modalities: { input: ["text", "image"], output: ["text"] },
      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
      limit: {
        context: model.contextWindow || 1048576,
        output: model.maxTokens || 65536,
      },
      family: "google",
    };
  }
  return entries;
}

/**
 * Register the Google provider in OpenCode config with discovered models.
 * @param {object} config - OpenCode config object (mutable)
 * @param {number} port - Proxy port
 * @param {Array<{ id: string, name: string, contextWindow?: number, maxTokens?: number }>} models
 * @returns {boolean} true if provider was registered/updated
 */
export function registerGoogleProvider(config, port, models) {
  if (!config.provider) config.provider = {};

  const providerModels = buildGoogleProviderModels(models);
  const baseURL = `http://127.0.0.1:${port}/v1beta`;

  const newProvider = {
    name: "Google (via aidevops proxy)",
    npm: "@ai-sdk/google",
    api: baseURL,
    models: providerModels,
  };

  const existing = config.provider.google;
  if (!existing || JSON.stringify(existing) !== JSON.stringify(newProvider)) {
    config.provider.google = newProvider;
    return true;
  }

  return false;
}

/**
 * Write the Google provider entry (with models) to opencode.json on disk.
 * @param {number} port - Proxy port
 * @param {Array<{ id: string, name: string, contextWindow?: number, maxTokens?: number }>} models
 */
export function persistGoogleProvider(port, models) {
  let config = {};
  try {
    const raw = readFileSync(OPENCODE_CONFIG_PATH, "utf-8");
    config = JSON.parse(raw);
  } catch (err) {
    if (err.code !== "ENOENT") {
      console.error(`[aidevops] Google proxy: cannot read opencode.json: ${err.message}`);
      return;
    }
  }

  if (!config.provider) config.provider = {};

  const providerModels = buildGoogleProviderModels(models);
  const baseURL = `http://127.0.0.1:${port}/v1beta`;

  config.provider.google = {
    name: "Google (via aidevops proxy)",
    npm: "@ai-sdk/google",
    api: baseURL,
    models: providerModels,
  };

  if (!process.env.GOOGLE_GENERATIVE_AI_API_KEY) {
    process.env.GOOGLE_GENERATIVE_AI_API_KEY = "google-pool-proxy";
  }

  try {
    mkdirSync(dirname(OPENCODE_CONFIG_PATH), { recursive: true });
    writeFileSync(OPENCODE_CONFIG_PATH, JSON.stringify(config, null, 2) + "\n", "utf-8");
    console.error(`[aidevops] Google proxy: persisted ${models.length} models to opencode.json (port ${port})`);
  } catch (err) {
    console.error(`[aidevops] Google proxy: failed to write opencode.json: ${err.message}`);
  }
}
