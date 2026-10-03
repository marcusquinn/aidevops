// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Experiment validation for model-ab-helper.mjs. Arms are either a single
// standard-tier model/effort (legacy) or a provider-family route per tier.
import { ALL_TIER_MODE, ROUTED_TIERS, validEnrollment } from "./model-ab-enrollment.mjs";
import { tieredArm } from "./model-ab-store.mjs";

export const MAX_WINDOW_HOURS = 168;
export const identifier = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/;
export const repoPattern = /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/;
const modelPattern = /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_./-]+$/;
const variants = ["low", "medium", "high", "xhigh", "max"];
const invalidExperiment = "invalid model A/B experiment: require ID, repository, seed, distinct issues and two model/effort arms";
const invalidWindow = `model A/B window must be a valid, bounded ${MAX_WINDOW_HOURS}-hour interval`;

function validIssues(issues) {
  if (!Array.isArray(issues)) return false;
  if (issues.length < 2 || new Set(issues).size !== issues.length) return false;
  return issues.every((issue) => Number.isSafeInteger(issue) && issue > 0);
}

// Provider-family routes may omit a variant to keep the provider default,
// e.g. Haiku 4.5, which has no low-effort variant.
function validRoute(route, variantOptional) {
  if (!route || typeof route !== "object" || !modelPattern.test(route.model || "")) return false;
  if (variantOptional && !Object.hasOwn(route, "variant")) return true;
  return variants.includes(route.variant);
}

function validTieredArm(arm) {
  if (Object.hasOwn(arm, "model") || !arm.tiers || typeof arm.tiers !== "object") return false;
  if (Object.keys(arm.tiers).length !== ROUTED_TIERS.length) return false;
  return ROUTED_TIERS.every((tier) => validRoute(arm.tiers[tier], true));
}

function validArm(arm) {
  if (!identifier.test(arm?.name || "")) return false;
  return tieredArm(arm) ? validTieredArm(arm) : validRoute(arm, false);
}

function validArms(arms) {
  if (!Array.isArray(arms) || arms.length !== 2) return false;
  if (new Set(arms.map((arm) => arm?.name)).size !== 2) return false;
  if (tieredArm(arms[0]) !== tieredArm(arms[1])) return false;
  return arms.every(validArm);
}

function validPopulation(value) {
  if (Object.hasOwn(value, "issues")) {
    return validIssues(value.issues) && !Object.hasOwn(value, "enrollment");
  }
  if (!validEnrollment(value)) return false;
  // All-tier enrollment needs a route for every tier it can enroll.
  return value.enrollment.mode !== ALL_TIER_MODE || tieredArm(value.arms?.[0]);
}

function validIdentity(value) {
  return identifier.test(value.id || "") && repoPattern.test(value.repo || "") && identifier.test(value.seed || "");
}

export function validateExperiment(value) {
  if (!value || typeof value !== "object" || !validIdentity(value)) throw new Error(invalidExperiment);
  if (!validArms(value.arms) || !validPopulation(value)) throw new Error(invalidExperiment);
  const start = Date.parse(value.starts_at);
  const end = Date.parse(value.ends_at);
  if (!Number.isFinite(start) || !Number.isFinite(end)) throw new Error(invalidWindow);
  if (end <= start || end - start > MAX_WINDOW_HOURS * 60 * 60 * 1000) throw new Error(invalidWindow);
  return value;
}
