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
  return normalizeModelVariant(value, ["low", "medium", "high"]);
}
