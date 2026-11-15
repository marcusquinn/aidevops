// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { activeLocalOnlyPolicy, isLocalProvider } from "./local-only-policy.mjs";
import { routingModelIdentity } from "./model-routing.mjs";

// GH#34125 follow-up (sb-local-setup, 2026-11-15): OpenCode's title-generation
// sub-call (and its `small_model` fallback) is dispatched by OpenCode core
// without ever invoking the `chat.params` hook, so `assertLocalOnlyEgress`
// never sees it — confirmed live: a bound session with no local `small_model`
// pin produced a `provider-auth`/`cache-stability` "family=aux" entry for the
// Anthropic-only request-transform pipeline (third-party-detection
// redistribution), proving the aux request reached Anthropic's native
// request body construction with zero VAULT_POLICY_DENIED for that session.
// `applyCompactionRouting` cannot cover this: compaction model selection is
// read by OpenCode core from `agent.compaction.model` (GH#35893) and its own
// requests DO cross `chat.params` (confirmed: compaction always logs
// `agent=compaction` there and is denied like any other call when bound).
// Title has no such hook visibility at all, so the only enforcement point is
// config-time: when bound, force `agent.title.model` and `small_model` onto
// the session's own (already-local, egress-gate-verified) primary model,
// unconditionally overriding any non-local pin — bound policy is absolute,
// unlike compaction's "only when unpinned" residency preference for unbound
// sessions.

/**
 * Force the title-generation model (and its `small_model` fallback) onto a
 * local provider when the session is bound to local-only policy. Unlike
 * `applyCompactionRouting`, this always overrides an existing non-local pin,
 * because title generation has no hook-level enforcement to fall back on.
 * @param {object} config - OpenCode Config object (mutable)
 * @param {object} [opts]
 * @param {ReturnType<typeof activeLocalOnlyPolicy>} [opts.policy]
 * @returns {boolean} whether a title/small_model route was forced
 */
export function applyLocalOnlyTitleRouting(config, { policy = activeLocalOnlyPolicy() } = {}) {
  if (!policy?.bound || !config) return false;
  const primaryModel = config.model;
  const { providerID: primaryProviderID } = routingModelIdentity(primaryModel);
  // Nothing safe to force onto: the primary model itself is not a classifiable
  // local provider (the egress gate still protects the main turn either way).
  if (!primaryProviderID || !isLocalProvider(policy, primaryProviderID)) return false;

  let changed = false;

  config.agent ??= {};
  const title = (config.agent.title ??= {});
  const titleProviderID = routingModelIdentity(title.model).providerID;
  if (!titleProviderID || !isLocalProvider(policy, titleProviderID)) {
    title.model = primaryModel;
    changed = true;
  }

  const smallProviderID = routingModelIdentity(config.small_model).providerID;
  if (!smallProviderID || !isLocalProvider(policy, smallProviderID)) {
    config.small_model = primaryModel;
    changed = true;
  }

  return changed;
}
