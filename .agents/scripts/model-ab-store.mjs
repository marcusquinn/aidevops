// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export function assignmentPaths(_experiment, repo, issue, directory) {
  // Key storage by issue, not experiment: overlapping trials may not switch
  // the arm of an already-assigned issue.
  const folder = join(directory, repo.replace("/", "__"));
  return { receipt: join(folder, `${issue}.json`), route: join(folder, `${issue}.routing.json`) };
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

export function persistRoute(paths, arm) {
  // Keep availability fallbacks and the normal thinking-tier escalation.
  const shipped = JSON.parse(readFileSync(new URL("../configs/model-routing-table.json", import.meta.url), "utf8"));
  const standard = shipped.tiers.standard;
  const route = { tiers: { standard: {
    models: [arm.model, ...standard.models.filter((model) => model !== arm.model)],
    reasoning: { ...standard.reasoning, [arm.model]: arm.variant },
  } } };
  const content = `${JSON.stringify(route)}\n`;
  try {
    writeFileSync(paths.route, content, { flag: "wx", mode: 0o600 });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    if (!lstatSync(paths.route).isFile()) throw new Error("model A/B route is not a regular file");
    if (readFileSync(paths.route, "utf8") !== content) {
      throw new Error("model A/B route changed: refusing a contaminated assignment");
    }
  }
}
