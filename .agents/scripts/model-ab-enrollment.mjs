// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

export const PROSPECTIVE_MODE = "new-standard-issues";
// All-tier enrollment for provider-family arms: every eligible auto-dispatch
// issue, whatever its workload tier, receives one arm route for all tiers.
export const ALL_TIER_MODE = "new-auto-dispatch-issues";
export const ROUTED_TIERS = ["simple", "standard", "thinking"];

export function validEnrollment(experiment) {
  if (!experiment.enrollment || typeof experiment.enrollment !== "object") return false;
  if (![PROSPECTIVE_MODE, ALL_TIER_MODE].includes(experiment.enrollment.mode)) return false;
  if (Object.keys(experiment.enrollment).length !== 1) return false;
  return !Object.hasOwn(experiment, "issues");
}

export function eligibleCreationDate(experiment, createdAt) {
  const created = Date.parse(createdAt);
  if (!Number.isFinite(created)) return false;
  if (created < Date.parse(experiment.starts_at)) return false;
  if (created >= Date.parse(experiment.ends_at)) return false;
  return true;
}

export function eligibleNewIssue(experiment, { createdAt, labels } = {}) {
  if (!eligibleCreationDate(experiment, createdAt)) return false;
  if (!Array.isArray(labels)) return false;
  if (!labels.every((label) => typeof label === "string")) return false;
  const names = new Set(labels);
  const required = ["auto-dispatch", "status:available"];
  const excluded = ["persistent", "parent-task", "no-auto-dispatch", "hold-for-review"];
  if (experiment.enrollment?.mode !== ALL_TIER_MODE) excluded.push("tier:simple", "tier:thinking");
  return required.every((name) => names.has(name)) && excluded.every((name) => !names.has(name));
}

export function parseAssignmentOptions(args) {
  const options = { continuationOnly: false };
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    if (flag === "--continuation-only") {
      if (options.continuationOnly) throw new Error("duplicate model A/B continuation flag");
      options.continuationOnly = true;
      continue;
    }
    const value = args[++index];
    if (!value) throw new Error(`missing model A/B option value: ${flag}`);
    if (flag === "--created-at") options.createdAt = value;
    else if (flag === "--labels-json") options.labels = JSON.parse(value);
    else if (flag === "--tier" && ROUTED_TIERS.includes(value)) options.tier = value;
    else throw new Error(`unknown model A/B option: ${flag}`);
  }
  return options;
}
