// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

export const PROSPECTIVE_MODE = "new-standard-issues";

export function validEnrollment(experiment) {
  if (!experiment.enrollment || typeof experiment.enrollment !== "object") return false;
  if (experiment.enrollment.mode !== PROSPECTIVE_MODE) return false;
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
  if (!names.has("auto-dispatch") || !names.has("status:available")) return false;
  if (names.has("tier:simple") || names.has("tier:thinking")) return false;
  if (names.has("persistent") || names.has("parent-task")) return false;
  if (names.has("no-auto-dispatch") || names.has("hold-for-review")) return false;
  return true;
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
    else throw new Error(`unknown model A/B option: ${flag}`);
  }
  return options;
}
