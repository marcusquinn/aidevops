#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Opt-in, issue-level initial-route assignment. An assignment never pins a
// worker: the existing availability fallback and capability escalation own
// recovery, and the observed route must be counted separately from this arm.
// Arms are either a single standard-tier model/effort (legacy) or a
// provider-family route covering simple, standard and thinking tiers, so a
// worker's escalations and OpenCode subagent delegations stay in the arm.
import { createHash } from "node:crypto";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { ROUTED_TIERS, eligibleNewIssue, parseAssignmentOptions } from "./model-ab-enrollment.mjs";
import { aggregateObserved, snapshotAssignments } from "./model-ab-report.mjs";
import { parseStartOptions, startProspectiveTrial } from "./model-ab-start.mjs";
import { assignmentPaths, persistReceipt, persistRoute, tieredArm } from "./model-ab-store.mjs";
import { repoPattern, validateExperiment } from "./model-ab-validate.mjs";

export { validateExperiment };

const root = join(homedir(), ".aidevops", ".agent-workspace", "work", "model-ab");

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function assignedArm(experiment, repo, issue) {
  if (experiment.enrollment) {
    const key = `${experiment.id}\0${experiment.seed}\0${repo}\0${issue}`;
    return experiment.arms[Number.parseInt(digest(key).slice(0, 8), 16) % 2];
  }
  // Predeclared cohort is shuffled by a stable seed, then blocked in pairs.
  // This prevents a tiny 48-hour cohort from randomly receiving only one arm.
  const shuffled = [...experiment.issues].sort((left, right) => {
    const a = digest(`${experiment.id}\0${experiment.seed}\0${repo}\0${left}`);
    const b = digest(`${experiment.id}\0${experiment.seed}\0${repo}\0${right}`);
    return a.localeCompare(b);
  });
  return experiment.arms[shuffled.indexOf(issue) % 2];
}

function armReceipt(arm) {
  if (!tieredArm(arm)) return { model: arm.model, variant: arm.variant };
  return { routes: ROUTED_TIERS
    .map((tier) => `${tier}=${arm.tiers[tier].model}@${arm.tiers[tier].variant || "default"}`)
    .join(",") };
}

export function assign(experiment, repo, issue, {
  directory = root, now = Date.now(), continuationOnly = false, createdAt, labels, tier,
} = {}) {
  validateExperiment(experiment);
  if (repo !== experiment.repo) return { active: false };
  if (experiment.issues && !experiment.issues.includes(issue)) return { active: false };
  const arm = assignedArm(experiment, repo, issue);
  const scope = tieredArm(arm) ? "all-tiers" : "standard";
  // Standard-only arms never start a new assignment from another tier; a
  // capability escalation keeps the issue's existing receipt only.
  const continuation = continuationOnly || (scope === "standard" && tier !== undefined && tier !== "standard");
  const fingerprint = digest(JSON.stringify(experiment));
  const paths = assignmentPaths(experiment, repo, issue, directory);
  if (!existsSync(paths.receipt) && experiment.enrollment) {
    if (!eligibleNewIssue(experiment, { createdAt, labels })) return { active: false };
  }
  if (!existsSync(paths.receipt)
    && (continuation || now < Date.parse(experiment.starts_at) || now >= Date.parse(experiment.ends_at))) {
    return { active: false };
  }
  const receipt = { schema: "aidevops-model-ab/v1", experiment: experiment.id,
    repo, issue, arm: arm.name, ...armReceipt(arm), fingerprint };
  if (experiment.enrollment) receipt.created_at = createdAt;
  const recorded = persistReceipt(paths, receipt, now);
  persistRoute(paths, arm);
  return { active: true, ...recorded, routing_table: paths.route, scope };
}

export function report(experiment, { directory = root } = {}) {
  validateExperiment(experiment);
  return snapshotAssignments(experiment, directory, assignedArm);
}

const usage = "usage: model-ab-helper.mjs start OWNER/REPO [--preset standard-luna-terra|openai-anthropic] [--hours N] | assign OWNER/REPO ISSUE [--created-at ISO --labels-json JSON] [--tier simple|standard|thinking] [--continuation-only] | report";

function run(argv) {
  const [command, repo, rawIssue] = argv;
  if (command === "start" && argv.length >= 2) {
    const options = parseStartOptions(argv.slice(2));
    process.stdout.write(`${JSON.stringify(startProspectiveTrial(repo, { ...options, validate: validateExperiment }))}\n`);
    return;
  }
  const config = process.env.AIDEVOPS_MODEL_AB_CONFIG;
  if (!config && command === "assign") { process.stdout.write('{"active":false}\n'); return; }
  if (!config) throw new Error("AIDEVOPS_MODEL_AB_CONFIG is required for report");
  const experiment = validateExperiment(JSON.parse(readFileSync(config, "utf8")));
  if (command === "assign" && repoPattern.test(repo || "") && /^[1-9][0-9]*$/.test(rawIssue || "")) {
    process.stdout.write(`${JSON.stringify(assign(experiment, repo, Number(rawIssue),
      parseAssignmentOptions(argv.slice(3))))}\n`);
  } else if (command === "report" && argv.length === 1) {
    process.stdout.write(`${JSON.stringify(aggregateObserved(report(experiment)))}\n`);
  } else {
    throw new Error(usage);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
  try { run(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
