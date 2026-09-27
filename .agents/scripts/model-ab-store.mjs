// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export function tieredArm(arm) {
  return Boolean(arm && typeof arm === "object" && Object.hasOwn(arm, "tiers"));
}

export function armModels(arm) {
  if (!tieredArm(arm)) return [arm.model];
  return [...new Set(Object.values(arm.tiers).map((route) => route.model))];
}

export function assignmentPaths(_experiment, repo, issue, directory) {
  // Key storage by issue, not experiment: overlapping trials may not switch
  // the arm of an already-assigned issue.
  const folder = join(directory, repo.replace("/", "__"));
  return { receipt: join(folder, `${issue}.json`), route: join(folder, `${issue}.routing.json`) };
}

export function assignedIssueNumbers(repo, directory) {
  const folder = join(directory, repo.replace("/", "__"));
  if (!existsSync(folder)) return [];
  return readdirSync(folder, { withFileTypes: true })
    .filter((entry) => entry.isFile() && /^[1-9][0-9]*\.json$/.test(entry.name))
    .map((entry) => Number(entry.name.slice(0, -5)))
    .sort((a, b) => a - b);
}

export function persistReceipt(paths, receipt, now) {
  let recorded = { ...receipt, assigned_at: new Date(now).toISOString() };
  mkdirSync(dirname(paths.receipt), { recursive: true, mode: 0o700 });
  try {
    writeFileSync(paths.receipt, `${JSON.stringify(recorded)}\n`, { flag: "wx", mode: 0o600 });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    if (!lstatSync(paths.receipt).isFile()) throw new Error("model A/B assignment is not a regular file");
    const existing = JSON.parse(readFileSync(paths.receipt, "utf8"));
    if (Object.keys(receipt).some((key) => existing[key] !== receipt[key])) {
      throw new Error("model A/B assignment changed: refusing to cross arms on retry");
    }
    if (!Number.isFinite(Date.parse(existing.assigned_at))) {
      throw new Error("model A/B assignment changed: refusing to cross arms on retry");
    }
    recorded = existing;
  }
  return recorded;
}

// Arm model first, then the shipped same-tier availability fallbacks. A
// legacy arm routes only the standard tier and keeps the normal thinking-tier
// escalation; a provider-family arm routes every tier.
export function armRoute(arm, shipped) {
  const routes = tieredArm(arm) ? arm.tiers : { standard: { model: arm.model, variant: arm.variant } };
  const tiers = {};
  for (const [tier, { model, variant }] of Object.entries(routes)) {
    const base = shipped?.tiers?.[tier] || {};
    const reasoning = { ...(base.reasoning || {}) };
    if (variant) reasoning[model] = variant;
    const fallbacks = (base.models || []).filter((candidate) => candidate !== model);
    tiers[tier] = { models: [model, ...fallbacks], reasoning };
  }
  return { tiers };
}

// Retries must keep the arm's primary model/effort per tier. Shipped fallback
// order may change between releases without contaminating the assignment.
function samePrimaries(existing, route) {
  const tiers = Object.keys(route.tiers);
  if (Object.keys(existing?.tiers || {}).length !== tiers.length) return false;
  return tiers.every((tier) => {
    const model = route.tiers[tier].models[0];
    const current = existing.tiers[tier];
    return current?.models?.[0] === model && current?.reasoning?.[model] === route.tiers[tier].reasoning[model];
  });
}

export function persistRoute(paths, arm) {
  const shipped = JSON.parse(readFileSync(new URL("../configs/model-routing-table.json", import.meta.url), "utf8"));
  const route = armRoute(arm, shipped);
  try {
    writeFileSync(paths.route, `${JSON.stringify(route)}\n`, { flag: "wx", mode: 0o600 });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    if (!lstatSync(paths.route).isFile()) throw new Error("model A/B route is not a regular file");
    if (!samePrimaries(JSON.parse(readFileSync(paths.route, "utf8")), route)) {
      throw new Error("model A/B route changed: refusing a contaminated assignment");
    }
  }
}
