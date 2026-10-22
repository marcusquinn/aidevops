// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Pure text/response helpers for capability-only subagent escalation.
 * Extracted from subagent-effort-escalation.mjs, which re-exports the public API.
 */

const TERMINAL_TOOL_FAILURES = new Set([
  "aborted", "cancelled", "canceled", "error", "failed",
]);
const FORBIDDEN_ESCALATION_EVIDENCE = /\b(?:auth(?:entication|orization)?|billing|credential|locality|permission|policy|provider|rate[ -]?limit|secret|trust[ -]?boundary)\b/i;

export const SIDE_EFFECT_SKIP = "[AIDEvOps automatic capability escalation skipped: the child attempted side effects, so parent review is required before retry.]";

export const ESCALATION_PROMPT = [
  "[AIDEvOps capability escalation]",
  "Continue the exact task in this session using the prior attempt and evidence.",
  "Do not repeat completed discovery. Produce the requested result and verification evidence.",
  "If model capability alone still blocks safe completion after bounded attempts, end with `BLOCKED: capability limit - <evidence>`.",
  "Never use that marker for permission, authentication, provider, rate-limit, secret, policy, trust-boundary, locality, billing, or side-effect uncertainty.",
].join("\n");

function responsePayload(response) {
  return response?.data ?? response ?? {};
}

export function responseError(response) {
  return response?.error || response?.data?.error || null;
}

export function responseText(response) {
  const payload = responsePayload(response);
  return (payload.parts || [])
    .filter((part) => part?.type === "text")
    .map((part) => part.text || "")
    .join("\n")
    .trim();
}

export function terminalToolFailure(status) {
  return TERMINAL_TOOL_FAILURES.has(status);
}

export function toolFailed(output) {
  const status = String(output?.metadata?.status || output?.status || "").toLowerCase();
  return terminalToolFailure(status);
}

/** Return safe capability-only evidence from the exact escalation marker. */
export function capabilityEscalationEvidence(value) {
  const match = String(value || "").match(/^BLOCKED: capability limit - ([^\r\n]+)$/im);
  const evidence = String(match?.[1] || "").trim();
  if (!evidence || FORBIDDEN_ESCALATION_EVIDENCE.test(evidence)) return "";
  return evidence;
}

/** Add the bounded failure contract once to an eligible child prompt. */
export function appendCapabilityEscalationContract(output) {
  const marker = "[AIDEvOps capability escalation contract]";
  const parts = Array.isArray(output?.parts) ? output.parts : [];
  if (parts.some((part) => part?.type === "text" && String(part.text || "").includes(marker))) return;
  const targetIndex = parts.findIndex((part) => part?.type === "text"
    && typeof part.id === "string"
    && typeof part.sessionID === "string"
    && typeof part.messageID === "string");
  if (targetIndex < 0) return;

  const contract = [
    marker,
    "After bounded attempts, emit `BLOCKED: capability limit - <evidence>` only when model capability is the sole blocker.",
    "Do not use it for permission, authentication, provider, rate-limit, secret, policy, trust-boundary, locality, billing, or side-effect uncertainty.",
  ].join("\n");
  const target = parts[targetIndex];
  const originalText = String(target.text || "");
  output.parts = parts.map((part, index) => index === targetIndex
    ? { ...target, text: originalText ? `${originalText}\n\n${contract}` : contract }
    : part);
}
