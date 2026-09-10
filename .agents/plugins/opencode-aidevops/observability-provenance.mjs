// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Normalise bounded, source-qualified request evidence for SQLite storage.
 * Runtime configuration is never represented as provider confirmation.
 */
export function requestProvenance(msg, routing, pricing) {
  const observedEffort = stringOrNull(msg?.variant);
  const requestedEffort = stringOrNull(routing?.requestedVariant);
  const resolvedEffort = stringOrNull(routing?.resolvedVariant || routing?.variant);
  return {
    requested_effort: requestedEffort,
    resolved_effort: resolvedEffort,
    observed_effort: observedEffort,
    effort_source: observedEffort ? "host_observed" : (resolvedEffort ? "routing_resolved" : "unknown"),
    provider_confirmed_effort: null,
    requested_model: stringOrNull(routing?.model),
    observed_model: stringOrNull(msg?.modelID),
    runtime_name: "opencode",
    runtime_version: stringOrNull(process.env.OPENCODE_VERSION),
    adapter_version: null,
    policy_fingerprint: null,
    billing_mode: null,
    cost_source: "local_estimate",
    pricing_quality: pricing?.quality || "unknown",
  };
}

function stringOrNull(value) {
  const normalized = String(value || "").trim();
  return normalized || null;
}
