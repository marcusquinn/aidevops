// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// ---------------------------------------------------------------------------
// Anthropic catalog bridge (GH#32848)
//
// OpenCode resolves `anthropic/<id>` against its cached models.dev catalog and
// fails with ProviderModelNotFoundError for models released after the last
// catalog publish. Framework routing may already name such a model (for
// example Claude Sonnet 5.5 on launch day). This bridge registers only those
// pending IDs, only while the host catalog lacks them, and never replaces a
// user-authored entry, so native metadata wins as soon as models.dev ships it.
// ---------------------------------------------------------------------------

import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

/** Catalog fields copied from the base model; everything else is dropped. */
const INHERITED_FIELDS = [
  "family", "attachment", "reasoning", "tool_call", "temperature",
  "modalities", "limit", "cost",
];

/**
 * Pending Anthropic models: `base` is the closest catalogued model whose
 * capabilities the new model shares; `def` holds verified launch facts.
 * Remove an entry once every supported OpenCode catalog includes it.
 */
export const PENDING_ANTHROPIC_MODELS = {};

/**
 * Read OpenCode's cached models.dev catalog.
 * @returns {object|null} parsed catalog, or null when unavailable
 */
export function loadHostModelCatalog() {
  const cacheRoot = process.env.XDG_CACHE_HOME || join(homedir(), ".cache");
  const path = join(cacheRoot, "opencode", "models.json");
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

function pickInherited(entry) {
  const out = {};
  for (const field of INHERITED_FIELDS) {
    if (entry?.[field] !== undefined) out[field] = entry[field];
  }
  return out;
}

/**
 * Register pending Anthropic models missing from the host catalog.
 * @param {object} config - OpenCode Config object (mutable)
 * @param {object|null} [catalog] - models.dev catalog (defaults to host cache)
 * @returns {number} number of models registered
 */
export function registerPendingAnthropicModels(config, catalog = loadHostModelCatalog()) {
  const catalogued = catalog?.anthropic?.models || {};
  let registered = 0;
  for (const [id, spec] of Object.entries(PENDING_ANTHROPIC_MODELS)) {
    if (catalogued[id]) continue;
    const existing = config?.provider?.anthropic?.models?.[id];
    if (existing) continue;
    const base = catalogued[spec.base];
    const inherited = base ? pickInherited(base) : { ...spec.fallback };
    if (!config.provider) config.provider = {};
    if (!config.provider.anthropic) config.provider.anthropic = {};
    if (!config.provider.anthropic.models) config.provider.anthropic.models = {};
    config.provider.anthropic.models[id] = { ...inherited, ...spec.def };
    registered += 1;
  }
  return registered;
}
