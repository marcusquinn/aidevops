// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Pricing lookup and cost calculation for the OpenCode observability plugin.
 *
 * The shared JSON remains the source of truth. Hardcoded values preserve
 * observability when that configuration is unavailable.
 *
 * @module observability-pricing
 */

import { readFileSync } from "fs";
import { homedir } from "os";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const HOME = homedir();
const FALLBACK_PRICING_VERSION = "2026-11-23.1";

/** Hardcoded fallback — used only when model-pricing.json is unreadable */
const FALLBACK_PRICING = {
  "opus-4":    { input: 15.0,  output: 75.0,  cacheRead: 1.50,   cacheWrite: 18.75 },
  "sonnet-4":  { input: 3.0,   output: 15.0,  cacheRead: 0.30,   cacheWrite: 3.75  },
  // Haiku 5.5: base rates up to 100K prompt tokens; prompts above 100K cost 5x.
  "haiku-5-5": {
    input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125,
    contextTiers: [{ above: 100000, input: 0.50, output: 2.50, cacheRead: 0.05, cacheWrite: 0.625 }],
  },
  "haiku-4":   { input: 0.80,  output: 4.0,   cacheRead: 0.08,   cacheWrite: 1.0   },
  "haiku-3":   { input: 0.80,  output: 4.0,   cacheRead: 0.08,   cacheWrite: 1.0   },
  "gpt-6-astra":   { input: 10.0, output: 50.0, cacheRead: 1.0, cacheWrite: 12.50 },
  "gpt-6.1-sol":   { input: 2.0,  output: 10.0, cacheRead: 0.10, cacheWrite: 2.50  },
  "gpt-6.1-terra": { input: 1.0,  output: 5.0,  cacheRead: 0.05, cacheWrite: 1.25  },
  "gpt-6-sol":     { input: 2.0,  output: 10.0, cacheRead: 0.20, cacheWrite: 2.50  },
  "gpt-6-luna":    { input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125 },
  "gpt-5.6-sol":   { input: 4.0,  output: 20.0, cacheRead: 0.40, cacheWrite: 5.0   },
  "gpt-5.6-terra": { input: 2.0,  output: 12.0, cacheRead: 0.20, cacheWrite: 2.50  },
  "gpt-5.6-luna":  { input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25  },
};
const FALLBACK_DEFAULT = { input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75 };
// Sol Pro has no published API price; never let substring matching assign Sol rates.
export const UNKNOWN_PRICING_MODELS = ["gpt-5.6-sol-pro"];

/**
 * Convert JSON `context_tiers` (snake_case) into ascending camelCase tiers.
 * A tier applies when prompt context tokens are strictly above `above`.
 * Invalid tiers are dropped so a malformed entry cannot corrupt estimates.
 * @param {unknown} tiers
 * @returns {Array<{above:number,input:number,output:number,cacheRead:number,cacheWrite:number}>}
 */
function normalizeContextTiers(tiers) {
  if (!Array.isArray(tiers)) return [];
  return tiers
    .map((tier) => ({
      above: Number(tier?.above),
      input: Number(tier?.input),
      output: Number(tier?.output),
      cacheRead: Number(tier?.cache_read),
      cacheWrite: Number(tier?.cache_write),
    }))
    .filter((tier) => Object.values(tier).every(Number.isFinite) && tier.above >= 0)
    .sort((a, b) => a.above - b.above);
}

/**
 * Load pricing from the shared JSON file.
 * The JSON uses snake_case keys (cache_read, cache_write) for cross-language
 * compatibility; we convert to camelCase for JS consumption.
 * @returns {{ models: Record<string, {input,output,cacheRead,cacheWrite,contextTiers?}>, default: {input,output,cacheRead,cacheWrite} }}
 */
function loadPricingFromJSON() {
  // Resolve relative to this file's location (works in both dev repo and deployed ~/.aidevops/)
  const thisDir = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    join(thisDir, "..", "..", "configs", "model-pricing.json"),          // repo: .agents/plugins/../../configs/
    join(HOME, ".aidevops", "agents", "configs", "model-pricing.json"), // deployed
  ];

  for (const candidate of candidates) {
    try {
      const raw = JSON.parse(readFileSync(candidate, "utf-8"));
      const models = {};
      for (const [key, p] of Object.entries(raw.models || {})) {
        models[key] = {
          input: p.input,
          output: p.output,
          cacheRead: p.cache_read,
          cacheWrite: p.cache_write,
        };
        const contextTiers = normalizeContextTiers(p.context_tiers);
        if (contextTiers.length > 0) models[key].contextTiers = contextTiers;
      }
      const def = raw.default || {};
      const defaultPricing = {
        input: def.input ?? 3.0,
        output: def.output ?? 15.0,
        cacheRead: def.cache_read ?? 0.30,
        cacheWrite: def.cache_write ?? 3.75,
      };
      return {
        models,
        default: defaultPricing,
        version: String(raw.version || FALLBACK_PRICING_VERSION),
      };
    } catch {
      // Try next candidate
    }
  }

  // All candidates failed — use hardcoded fallback
  console.error("[aidevops] Observability: model-pricing.json not found, using hardcoded fallback");
  return {
    models: FALLBACK_PRICING,
    default: FALLBACK_DEFAULT,
    version: FALLBACK_PRICING_VERSION,
  };
}

const pricing = loadPricingFromJSON();
export const MODEL_PRICING = pricing.models;
export const DEFAULT_PRICING = pricing.default;
export const PRICING_VERSION = pricing.version;

/** Match a model ID to its table entry, including any context tiers. */
function matchPricingEntry(modelID) {
  if (!modelID) return DEFAULT_PRICING;
  const lower = modelID.toLowerCase();
  if (UNKNOWN_PRICING_MODELS.some((model) => lower.includes(model))) return DEFAULT_PRICING;
  for (const [key, modelPricing] of Object.entries(MODEL_PRICING)) {
    if (lower.includes(key)) return modelPricing;
  }
  return DEFAULT_PRICING;
}

/**
 * Prompt context size used for context-tier billing: uncached input plus
 * cache reads and cache writes (OpenCode reports `input` excluding cache).
 * @param {object} tokens - { input, cache: { read, write } }
 * @returns {number}
 */
export function getPromptContextTokens(tokens) {
  if (!tokens) return 0;
  return (tokens.input || 0) + (tokens.cache?.read || 0) + (tokens.cache?.write || 0);
}

/**
 * Select flat rates for a prompt size. The highest tier whose `above`
 * threshold the context exceeds wins; otherwise the base rates apply.
 * @param {{input,output,cacheRead,cacheWrite,contextTiers?}} entry
 * @param {number} contextTokens
 * @returns {{ input: number, output: number, cacheRead: number, cacheWrite: number }}
 */
export function resolveContextTier(entry, contextTokens = 0) {
  let selected = entry;
  for (const tier of entry.contextTiers || []) {
    if (contextTokens > tier.above) selected = tier;
  }
  return {
    input: selected.input,
    output: selected.output,
    cacheRead: selected.cacheRead,
    cacheWrite: selected.cacheWrite,
  };
}

/**
 * Look up pricing for a model ID. Matches against the pricing table keys
 * as substrings of the model ID (e.g., "claude-sonnet-4-20250514" matches "sonnet-4").
 * Without `contextTokens`, returns the base (shortest-context) rates.
 * @param {string} modelID
 * @param {number} [contextTokens] - prompt context size; see getPromptContextTokens
 * @returns {{ input: number, output: number, cacheRead: number, cacheWrite: number }}
 */
export function getPricing(modelID, contextTokens = 0) {
  return resolveContextTier(matchPricingEntry(modelID), contextTokens);
}

/** Return the price and the evidence quality used to select it. */
export function getPricingProvenance(modelID, contextTokens = 0) {
  const lower = String(modelID || "").toLowerCase();
  const pricing = getPricing(modelID, contextTokens);
  if (!lower || UNKNOWN_PRICING_MODELS.some((model) => lower.includes(model))) {
    return { pricing, quality: "unknown" };
  }
  if (Object.keys(MODEL_PRICING).some((key) => lower.includes(key))) {
    return { pricing, quality: "exact_model" };
  }
  return { pricing, quality: "fallback" };
}

/**
 * Calculate cost from token counts and model pricing.
 * OpenCode does not provide cost in message events — we must compute it.
 * Context-tiered models (Haiku 5.5 above 100K) price the whole request at
 * the tier selected by its prompt context size.
 * @param {object} tokens - { input, output, reasoning, cache: { read, write } }
 * @param {string} modelID
 * @returns {number} Total cost in USD
 */
export function calculateCost(tokens, modelID) {
  if (!tokens) return 0.0;
  const modelPricing = getPricing(modelID, getPromptContextTokens(tokens));
  const inputTokens = tokens.input || 0;
  const outputTokens = tokens.output || 0;
  const reasoningTokens = tokens.reasoning || 0;
  const cacheRead = tokens.cache?.read || 0;
  const cacheWrite = tokens.cache?.write || 0;

  // Reasoning tokens are billed at output rate
  const cost =
    (inputTokens / 1e6) * modelPricing.input +
    ((outputTokens + reasoningTokens) / 1e6) * modelPricing.output +
    (cacheRead / 1e6) * modelPricing.cacheRead +
    (cacheWrite / 1e6) * modelPricing.cacheWrite;

  return Math.round(cost * 1e8) / 1e8; // 8 decimal places
}
