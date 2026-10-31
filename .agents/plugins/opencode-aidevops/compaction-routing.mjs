// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { DEFAULT_COMPACTION_TARGET } from "./context-budget-policy.mjs";
import { activeLocalOnlyPolicy, configuredLocalProviders, isLocalProvider } from "./local-only-policy.mjs";
import { CLAUDE_MODEL_LIMITS } from "./model-limits.mjs";
import { routingCandidates, routingModelIdentity } from "./model-routing.mjs";
import { compactionReasoning } from "./model-routing-variant.mjs";
import { optionsHaveCredentials } from "./provider-credentials.mjs";

// Fixed compaction effort (GH#36169) lives in compaction-effort.mjs.

// Catalog env keys for providers the shipped simple tier names. Other remote
// providers need stored auth, a configured env list, or credential options.
const PROVIDER_ENV_KEYS = {
  openai: ["OPENAI_API_KEY"],
  anthropic: ["ANTHROPIC_API_KEY"],
};

function claudeCatalogInputLimit(providerID, modelID) {
  if (providerID !== "anthropic") return 0;
  const limit = CLAUDE_MODEL_LIMITS[modelID];
  return limit ? limit.context - limit.output : 0;
}

// Native catalog models (Haiku 5.5) have no config.provider entry; fall back
// to the managed Claude limits rather than treating them as too small.
function inputLimit(config, model) {
  const { providerID, modelID } = routingModelIdentity(model);
  const limit = config?.provider?.[providerID]?.models?.[modelID]?.limit;
  if (!limit || typeof limit !== "object") return claudeCatalogInputLimit(providerID, modelID);
  if (Number.isFinite(limit.input)) return limit.input;
  if (Number.isFinite(limit.context) && Number.isFinite(limit.output)) {
    return limit.context - limit.output;
  }
  return claudeCatalogInputLimit(providerID, modelID);
}

/** Provider IDs with stored OpenCode credentials; key names only, never values. */
export function storedAuthProviders(env = process.env) {
  const dataHome = env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  try {
    const parsed = JSON.parse(readFileSync(join(dataHome, "opencode", "auth.json"), "utf8"));
    return new Set(parsed && typeof parsed === "object" ? Object.keys(parsed) : []);
  } catch {
    return new Set();
  }
}

/**
 * Config-time credential check for compaction candidates (GH#36169). The
 * plugin always writes `config.provider.openai`, which OpenCode lists as a
 * `source: "config"` provider even without a key, so an uncredentialed Luna
 * route fails with "OpenAI API key is missing" instead of falling back.
 * @returns {(providerID: string) => boolean}
 */
export function createCompactionCredentialCheck(config, {
  env = process.env,
  authProviders = () => storedAuthProviders(env),
  localProviders = () => configuredLocalProviders(),
} = {}) {
  let stored = null;
  let local = null;
  const enabled = Array.isArray(config?.enabled_providers) ? config.enabled_providers : null;
  const disabled = Array.isArray(config?.disabled_providers) ? config.disabled_providers : [];
  return (providerID) => {
    if (!providerID || disabled.includes(providerID)) return false;
    if (enabled && !enabled.includes(providerID)) return false;
    local ??= (typeof localProviders === "function" ? localProviders() : localProviders) || [];
    if (local.includes(providerID)) return true;
    stored ??= typeof authProviders === "function" ? authProviders() : authProviders;
    if (stored?.has?.(providerID)) return true;
    const definition = config?.provider?.[providerID] || {};
    const envKeys = [...(PROVIDER_ENV_KEYS[providerID] || []), ...(Array.isArray(definition.env) ? definition.env : [])];
    if (envKeys.some((key) => Boolean(env?.[key]))) return true;
    return optionsHaveCredentials(definition.options);
  };
}

// GH#35893: OpenCode 1.x reads the compaction model only from global agent
// config (session/compaction.ts: `agent.model ?? userMessage.model`); no hook
// can change it per session. Residency is therefore decided here, once:
// - bound local-only policy: only local candidates, else the (local) parent;
// - unbound with a local default `config.model`: same, from the configured
//   local-provider list, so a local session's history stays on the device;
// - otherwise: every candidate, as before.
function allowedCompactionProvider(config, policy, localProviders) {
  if (policy?.bound) return (providerID) => isLocalProvider(policy, providerID);
  const { providerID: defaultProvider } = routingModelIdentity(config?.model);
  if (!defaultProvider) return () => true;
  const local = typeof localProviders === "function" ? localProviders() : localProviders;
  if (!local?.includes(defaultProvider)) return () => true;
  return (providerID) => local.includes(providerID);
}

/**
 * Route unpinned OpenCode compaction summaries to the first simple-tier
 * candidate that has usable credentials, can accept the full managed
 * compaction input, and is allowed by local-provider residency. Unusable
 * candidates are skipped (no OpenAI credentials: Luna -> Haiku 5.5); with no
 * fitting candidate compaction stays on the parent model.
 * @param {object} config - OpenCode Config object (mutable)
 * @param {object} routing - resolved aidevops routing table
 * @param {object} [opts] - `policy` (local-only binding), `localProviders`
 *   (list or thunk; read only when the default model needs classifying) and
 *   `hasCredentials(providerID)` (defaults to createCompactionCredentialCheck)
 * @returns {boolean} whether a compaction route was applied
 */
export function applyCompactionRouting(config, routing, {
  policy = activeLocalOnlyPolicy(),
  localProviders = () => configuredLocalProviders(),
  hasCredentials = createCompactionCredentialCheck(config, { localProviders }),
} = {}) {
  if (!config || !routing) return false;
  config.agent ??= {};
  const compaction = config.agent.compaction ??= {};
  if (String(compaction.model || "") || String(compaction.variant || "")) return false;

  const allowed = allowedCompactionProvider(config, policy, localProviders);
  for (const model of routingCandidates(routing, "simple")) {
    const { providerID } = routingModelIdentity(model);
    if (!allowed(providerID) || !hasCredentials(providerID)) continue;
    if (inputLimit(config, model) < DEFAULT_COMPACTION_TARGET) continue;
    compaction.model = model;
    // Informational: OpenCode ignores it for compaction; chat.params applies it.
    compaction.variant = compactionReasoning(routing.compactionReasoning);
    return true;
  }
  return false;
}

export function compactionAgent(input) {
  return typeof input?.agent === "string" ? input.agent : input?.agent?.name;
}

/**
 * Warn once per process when an unbound session whose last model was local
 * is compacted on a non-local provider (GH#35893). Config-time routing cannot
 * see a session that switched to a local model after startup. Content-free:
 * only provider IDs are logged. Bound sessions never get here, because the
 * egress gate refuses the request first.
 * @param {object} [opts] - `localProviders` (list or thunk), `log(level, msg)`
 * @returns {(input: object, parentModel: string) => boolean} true when warned
 */
export function createCompactionResidencyWarning({
  localProviders = () => configuredLocalProviders(),
  log,
} = {}) {
  let warned = false;
  return (input, parentModel) => {
    if (warned || compactionAgent(input) !== "compaction") return false;
    const parentProvider = routingModelIdentity(parentModel).providerID;
    const provider = String(input?.model?.providerID ?? input?.provider?.id ?? "");
    if (!parentProvider || !provider || parentProvider === provider) return false;
    const local = typeof localProviders === "function" ? localProviders() : localProviders;
    if (!local?.includes(parentProvider) || local.includes(provider)) return false;
    warned = true;
    log?.("WARN", `[compaction] local provider "${parentProvider}" session compacted on non-local provider `
      + `"${provider}"; pin agent.compaction.model to a local model or launch with AIDEVOPS_RUNTIME_POLICY=local-only`);
    return true;
  };
}
