// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

function normalizeModelVariant(value, allowedVariants) {
  if (typeof value?.model !== "string" || !value.model.includes("/")) return null;
  if (!allowedVariants.includes(value.variant)) return null;
  return { model: value.model, variant: value.variant };
}

export function normalizeInteractiveDefault(value) {
  return normalizeModelVariant(value, ["low", "medium", "high", "xhigh", "max"]);
}

export function normalizeSpecialistAdvisor(value) {
  const normalized = normalizeModelVariant(value, ["low", "medium", "high"]);
  if (normalized?.variant === "low") normalized.variant = "medium";
  return normalized;
}

export function reasoningFloor(value) {
  return ["high", "xhigh", "max"].includes(value) ? value : "medium";
}

/** Compaction summaries default to `high`; only medium..max are accepted (GH#36169). */
export const COMPACTION_REASONING_DEFAULT = "high";

export function compactionReasoning(value) {
  return ["medium", "high", "xhigh", "max"].includes(value) ? value : COMPACTION_REASONING_DEFAULT;
}

export function floorReasoning(variant, minimum = "medium") {
  if (!variant) return ""; // Unknown variants retain the provider default.
  const levels = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
  const floor = reasoningFloor(minimum);
  return levels.indexOf(variant) < levels.indexOf(floor) ? floor : variant;
}
