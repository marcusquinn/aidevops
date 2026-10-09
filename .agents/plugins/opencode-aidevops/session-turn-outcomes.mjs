// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#34138: content-free outcome classes and user-facing toast text for
// session-turn-diagnostics.mjs. Nothing here reads message or tool content.

import { normalizeProviderError } from "./provider-error-diagnostics.mjs";

const KNOWN_ERROR_NAMES = new Set([
  "APIError",
  "MessageAbortedError",
  "MessageOutputLengthError",
  "ProviderAuthError",
  "UnknownError",
]);

const ERROR_OUTCOMES = new Map([
  ["MessageAbortedError", () => ({ kind: "cancelled" })],
  ["MessageOutputLengthError", () => ({ kind: "output_limit" })],
  ["ProviderAuthError", () => ({ kind: "provider_error", classification: "authentication_failed", status_code: null })],
  ["APIError", (error) => {
    const diagnostic = normalizeProviderError(error);
    return { kind: "provider_error", classification: diagnostic.classification, status_code: diagnostic.status_code };
  }],
]);

// The provider-error handler already explains these with its own toast.
const EXPLAINED_ELSEWHERE = new Set(["gateway_denied", "access_denied"]);
const SILENT_OUTCOMES = new Set(["answered", "cancelled", "tool_only"]);

/** Reduce an OpenCode error object to a content-free outcome class. */
export function classifyError(error) {
  if (!error || typeof error !== "object") return null;
  const name = String(error.name || "");
  const outcome = ERROR_OUTCOMES.get(name);
  if (outcome) return outcome(error);
  return { kind: "runtime_error", name: KNOWN_ERROR_NAMES.has(name) ? name : "unknown" };
}

function endedOutcome(state) {
  if (state.textSeen) return "answered";
  // A user shell command (`!cmd`) runs a tool without a model step; its
  // output is the visible reply.
  if (state.toolSeen && !state.stepSeen) return "tool_only";
  return "no_response";
}

function busyOutcome(state) {
  if (state.pendingPermissionIDs.size > 0) return "permission_wait";
  if (state.activeTools.size > 0) return "tool_wait";
  return state.status === "retry" ? "provider_retry" : "no_activity";
}

/**
 * Classify a turn from tracked metadata. `ended` distinguishes an idle
 * boundary from a still-busy turn that has gone quiet.
 */
export function classifyTurn(state, { ended }) {
  if (state.error?.kind) return state.error.kind;
  return ended ? endedOutcome(state) : busyOutcome(state);
}

function minutes(milliseconds) {
  return Math.max(1, Math.round(milliseconds / 60_000));
}

function providerDetail(error) {
  if (error?.status_code) return `HTTP ${error.status_code}`;
  return String(error?.classification || "provider_error").replace(/_/g, " ");
}

const NOT_RETRIED = "Nothing was retried automatically.";

const MESSAGES = {
  no_response: () => `The assistant turn ended without a visible reply. Metadata shows no provider error, cancellation, or pending permission, so the cause is unknown. ${NOT_RETRIED} Ask for status or resend.`,
  provider_error: (state) => `The provider request failed (${providerDetail(state.error)}), so the reply is missing or incomplete. ${NOT_RETRIED} Resend or switch model when ready.`,
  output_limit: () => "The reply stopped at the model output limit. Ask the assistant to continue from where it stopped.",
  runtime_error: (state) => `The turn ended with a runtime error (${state.error?.name || "unknown"}), so the reply is missing or incomplete. ${NOT_RETRIED}`,
  permission_wait: (_state, idleMs) => `Waiting ${minutes(idleMs)}m for a permission reply. The session is paused, not stuck; answer the permission prompt to continue.`,
  tool_wait: (state, idleMs) => `A ${[...state.activeTools.values()].at(-1)} tool call has run for ${minutes(idleMs)}m with no other activity. The session is waiting on the tool, not the model.`,
  provider_retry: (_state, idleMs) => `The provider has been retrying for ${minutes(idleMs)}m. The session is waiting on the provider; ${NOT_RETRIED.toLowerCase()}`,
  no_activity: (_state, idleMs) => `No model or tool activity for ${minutes(idleMs)}m. Metadata cannot tell a stalled provider stream from an event-delivery gap. ${NOT_RETRIED}`,
};

const TITLES = {
  no_response: "No reply",
  provider_error: "Reply interrupted",
  runtime_error: "Reply interrupted",
  output_limit: "Reply truncated",
};

/** Build the toast body for an outcome, or null when it has no message. */
export function toastFor(outcome, state, idleMs) {
  const message = MESSAGES[outcome]?.(state, idleMs);
  if (!message) return null;
  return {
    title: TITLES[outcome] || "Still waiting",
    message,
    variant: "warning",
    duration: 15000,
  };
}

/** True when an outcome needs a toast that this turn has not shown yet. */
export function shouldNotify(outcome, state) {
  if (SILENT_OUTCOMES.has(outcome)) return false;
  if (outcome === "provider_error" && EXPLAINED_ELSEWHERE.has(state.error?.classification)) return false;
  return !state.notified.has(outcome);
}
