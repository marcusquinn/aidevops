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

export function floorReasoning(variant, minimum = "medium") {
  if (!variant) return ""; // Unknown variants retain the provider default.
  const levels = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];
  const floor = reasoningFloor(minimum);
  return levels.indexOf(variant) < levels.indexOf(floor) ? floor : variant;
}
