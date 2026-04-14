// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Shared OpenCode provider-model entry builder used by all proxy plugins
 * (claude-proxy, cursor-proxy, google-proxy). Each proxy registers a
 * `provider.<id>` block in opencode.json whose `models` map describes the
 * runtime capabilities of every model the proxy can route to.
 *
 * The shape of each entry is fixed by OpenCode's @ai-sdk/openai-compatible
 * provider — see opencode-ai source for the canonical schema. The previous
 * implementation duplicated this builder across each proxy file, with only
 * `family` and a few capability flags differing. Centralising it eliminates
 * the qlty similar-code smell (was 20 lines in 2 locations, mass=89) and
 * keeps schema drift in one place.
 *
 * Extracted from claude-proxy.mjs and cursor-proxy.mjs as part of t2070.
 */

/**
 * @typedef {Object} ProxyModel
 * @property {string} id
 * @property {string} name
 * @property {boolean} [reasoning]
 * @property {number} [contextWindow]
 * @property {number} [maxTokens]
 */

/**
 * @typedef {Object} ProxyProviderModelOpts
 * @property {string} family - OpenCode family identifier (e.g. "claudecli", "cursor", "google")
 * @property {boolean} [attachment=false] - Whether models accept attachments
 * @property {boolean} [toolCall=false]   - Whether models support tool/function calls
 * @property {boolean} [temperature=true] - Whether models accept a temperature parameter
 * @property {string[]} [inputModalities=["text"]]  - Input modality list
 * @property {string[]} [outputModalities=["text"]] - Output modality list
 * @property {number} [defaultContext=200000]    - Fallback context window
 * @property {number} [defaultMaxTokens=32000]   - Fallback max-output tokens
 * @property {(model: ProxyModel) => boolean} [reasoningFn] - Custom reasoning predicate
 */

/**
 * Build an OpenCode provider `models` map from a proxy's discovered model list.
 *
 * @param {ProxyModel[]} models
 * @param {ProxyProviderModelOpts} opts
 * @returns {Record<string, object>}
 */
export function buildProviderModels(models, opts) {
  const {
    family,
    attachment = false,
    toolCall = false,
    temperature = true,
    inputModalities = ["text"],
    outputModalities = ["text"],
    defaultContext = 200000,
    defaultMaxTokens = 32000,
    reasoningFn = (model) => Boolean(model.reasoning),
  } = opts;

  const entries = {};
  for (const model of models) {
    entries[model.id] = {
      name: model.name,
      attachment,
      tool_call: toolCall,
      temperature,
      reasoning: reasoningFn(model),
      modalities: { input: inputModalities, output: outputModalities },
      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
      limit: {
        context: model.contextWindow || defaultContext,
        output: model.maxTokens || defaultMaxTokens,
      },
      family,
    };
  }
  return entries;
}
