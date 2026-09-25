#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Opt-in, issue-level initial-route assignment. An assignment never pins a
// worker: the existing availability fallback and capability escalation own
// recovery, and the observed route must be counted separately from this arm.
import { createHash } from "node:crypto";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { eligibleCreationDate, eligibleNewIssue, parseAssignmentOptions, validEnrollment } from "./model-ab-enrollment.mjs";
import { aggregateObserved } from "./model-ab-report.mjs";
import { startProspectiveTrial } from "./model-ab-start.mjs";
import { assignedIssueNumbers, assignmentPaths, persistReceipt, persistRoute } from "./model-ab-store.mjs";

const root = join(homedir(), ".aidevops", ".agent-workspace", "work", "model-ab");
const identifier = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/;
const repoPattern = /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/;
const modelPattern = /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_./-]+$/;
const invalidExperiment = "invalid model A/B experiment: require ID, repository, seed, distinct issues and two model/effort arms";

function digest(value) {
  return createHash("sha256").update(value).digest("hex");
}

function validIssues(issues) {
  if (!Array.isArray(issues)) return false;
  if (issues.length < 2 || new Set(issues).size !== issues.length) return false;
  return issues.every((issue) => Number.isSafeInteger(issue) && issue > 0);
}

function validArm(arm) {
  if (!identifier.test(arm?.name || "")) return false;
  if (!modelPattern.test(arm?.model || "")) return false;
  return ["low", "medium", "high", "max"].includes(arm?.variant);
}

function validArms(arms) {
  if (!Array.isArray(arms) || arms.length !== 2) return false;
  if (new Set(arms.map((arm) => arm?.name)).size !== 2) return false;
  return arms.every(validArm);
}

export function validateExperiment(value) {
  if (!value || typeof value !== "object") {
    throw new Error(invalidExperiment);
  }
  if (!identifier.test(value.id || "") || !repoPattern.test(value.repo || "")) {
    throw new Error(invalidExperiment);
  }
  if (!identifier.test(value.seed || "")) throw new Error(invalidExperiment);
  if (Object.hasOwn(value, "issues")) {
    if (!validIssues(value.issues) || Object.hasOwn(value, "enrollment")) throw new Error(invalidExperiment);
  } else if (!validEnrollment(value)) throw new Error(invalidExperiment);
  if (!validArms(value.arms)) throw new Error(invalidExperiment);
  const start = Date.parse(value.starts_at);
  const end = Date.parse(value.ends_at);
  if (!Number.isFinite(start) || !Number.isFinite(end)) {
    throw new Error("model A/B window must be a valid, bounded 72-hour interval");
  }
  if (end <= start || end - start > 72 * 60 * 60 * 1000) {
    throw new Error("model A/B window must be a valid, bounded 72-hour interval");
  }
  return value;
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

export function assign(experiment, repo, issue, {
  directory = root, now = Date.now(), continuationOnly = false, createdAt, labels,
} = {}) {
  validateExperiment(experiment);
  if (repo !== experiment.repo) return { active: false };
  if (experiment.issues && !experiment.issues.includes(issue)) return { active: false };
  const arm = assignedArm(experiment, repo, issue);
  const fingerprint = digest(JSON.stringify(experiment));
  const paths = assignmentPaths(experiment, repo, issue, directory);
  if (!existsSync(paths.receipt) && experiment.enrollment) {
    if (!eligibleNewIssue(experiment, { createdAt, labels })) return { active: false };
  }
  if (!existsSync(paths.receipt)
    && (continuationOnly || now < Date.parse(experiment.starts_at) || now >= Date.parse(experiment.ends_at))) {
    return { active: false };
  }
  const receipt = { schema: "aidevops-model-ab/v1", experiment: experiment.id,
    repo, issue, arm: arm.name, model: arm.model, variant: arm.variant, fingerprint };
  if (experiment.enrollment) receipt.created_at = createdAt;
  const recorded = persistReceipt(paths, receipt, now);
  persistRoute(paths, arm);
  return { active: true, ...recorded, routing_table: paths.route };
}

export function report(experiment, { directory = root } = {}) {
  validateExperiment(experiment);
  const arms = Object.fromEntries(experiment.arms.map((arm) => [arm.name, { assigned: 0, issues: [], assignments: [] }]));
  const excluded = [];
  const issues = experiment.issues || assignedIssueNumbers(experiment.repo, directory);
  for (const issue of issues) {
    const { receipt } = assignmentPaths(experiment, experiment.repo, issue, directory);
    if (!existsSync(receipt)) { excluded.push(issue); continue; }
    const item = JSON.parse(readFileSync(receipt, "utf8"));
    if (experiment.enrollment && item.experiment !== experiment.id) continue;
    if (item.fingerprint !== digest(JSON.stringify(experiment))
      || item.arm !== assignedArm(experiment, experiment.repo, issue).name
      || !Number.isFinite(Date.parse(item.assigned_at))) {
      throw new Error("model A/B report refused changed assignment evidence");
    }
    if (experiment.enrollment && !eligibleCreationDate(experiment, item.created_at)) {
      throw new Error("model A/B report refused ineligible prospective assignment");
    }
    arms[item.arm].assigned += 1;
    arms[item.arm].issues.push(issue);
    arms[item.arm].assignments.push({ issue, assigned_at: item.assigned_at });
  }
  return { experiment: experiment.id, repo: experiment.repo, arms, excluded,
    result: "assignment-only: join observed requests, escalations, merged-PR evidence and parent acceptance before comparing outcomes" };
}

function run(argv) {
  const [command, repo, rawIssue] = argv;
  if (command === "start" && argv.length === 2) {
    process.stdout.write(`${JSON.stringify(startProspectiveTrial(repo, { validate: validateExperiment }))}\n`);
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
    throw new Error("usage: model-ab-helper.mjs start OWNER/REPO | assign OWNER/REPO ISSUE [--created-at ISO --labels-json JSON] [--continuation-only] | report");
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
  try { run(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
