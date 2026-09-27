// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { validateExperiment } from "../../scripts/model-ab-validate.mjs";
import { mergeModelRouting } from "./model-routing.mjs";

// Explicit private opt-in. Invalid or expired trials cannot silently change routing.
export function loadSubagentTrial(path = process.env.AIDEVOPS_SUBAGENT_AB_CONFIG, now = Date.now()) {
  if (!path || process.env.AIDEVOPS_HEADLESS || process.env.AIDEVOPS_DISPATCH_TIER) return null;
  const experiment = validateExperiment(JSON.parse(readFileSync(path, "utf8")));
  if (!experiment.enrollment || experiment.arms.some((arm) => !arm.tiers)) {
    throw new Error("interactive subagent A/B requires two all-tier arms");
  }
  return now >= Date.parse(experiment.starts_at) && now < Date.parse(experiment.ends_at)
    ? experiment : null;
}

export function subagentArm(experiment, sessionID) {
  const key = `${experiment.id}\0${experiment.seed}\0${sessionID}`;
  const hash = createHash("sha256").update(key).digest("hex");
  return experiment.arms[Number.parseInt(hash.slice(0, 8), 16) % 2];
}

export function armRouting(base, arm) {
  const tiers = Object.fromEntries(Object.entries(arm.tiers).map(([tier, route]) => [tier, {
    models: [route.model, ...base.tiers[tier].models.filter((model) => model !== route.model)],
    reasoning: route.variant ? { [route.model]: route.variant } : {},
  }]));
  return mergeModelRouting(base, { tiers });
}
