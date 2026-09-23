// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { assign, assignedArm, report, validateExperiment } from "../model-ab-helper.mjs";
import { aggregateObserved } from "../model-ab-report.mjs";
import { loadModelRouting, routingPrimary, routingVariant } from "../../plugins/opencode-aidevops/model-routing.mjs";

const windowStart = Date.parse("2026-09-23T00:00:00Z");
const experiment = {
  id: "standard-route-trial", repo: "example/repo", seed: "cohort-a",
  starts_at: "2026-09-23T00:00:00Z", ends_at: "2026-09-25T00:00:00Z",
  issues: [12, 13, 14, 15],
  arms: [
    { name: "luna-max", model: "openai/gpt-6-luna", variant: "max" },
    { name: "terra-low", model: "openai/gpt-5.6-terra", variant: "low" },
  ],
};

test("issue arms persist across retries without changing the fallback or thinking routes", () => {
  const parent = process.env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  const directory = mkdtempSync(join(parent, "model-ab-test-"));
  try {
    const first = assign(experiment, "example/repo", 12, { directory, now: windowStart + 1 });
    const retry = assign(experiment, "example/repo", 12, { directory, now: windowStart + 2 });
    assert.deepEqual(first, retry);
    assert.equal(first.arm, assignedArm(experiment, "example/repo", 12).name);
    const route = JSON.parse(readFileSync(first.routing_table, "utf8"));
    assert.equal(route.tiers.standard.models[0], first.model);
    assert.equal(route.tiers.standard.reasoning[first.model], first.variant);
    assert.ok(route.tiers.standard.models.includes("anthropic/claude-sonnet-4-6"));
    assert.equal(route.tiers.thinking, undefined);
    const shipped = fileURLToPath(new URL("../../configs/model-routing-table.json", import.meta.url));
    const merged = loadModelRouting([first.routing_table, shipped]);
    assert.equal(routingPrimary(merged, "standard"), first.model);
    assert.equal(routingVariant(merged, "standard", first.model), first.variant);
    assert.equal(routingPrimary(merged, "thinking"), "openai/gpt-6-sol");
    assert.equal(report(experiment, { directory }).arms[first.arm].assigned, 1);
    assert.equal(report(experiment, { directory }).excluded.length, 3);
    assert.deepEqual(assign(experiment, "example/repo", 12, { directory, now: windowStart + 72 * 3600 * 1000 }), first);
    assert.equal(assign(experiment, "example/repo", 13, { directory, now: windowStart - 1 }).active, false);
    assert.equal(assign(experiment, "other/repo", 12, { directory, now: windowStart + 1 }).active, false);
    assert.throws(() => assign({ ...experiment, seed: "changed" }, "example/repo", 12,
      { directory, now: windowStart + 1 }), /assignment changed/);
    assert.throws(() => assign({ ...experiment, id: "competing-trial" }, "example/repo", 12,
      { directory, now: windowStart + 1 }), /assignment changed/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("configuration requires a bounded window and distinct issue population", () => {
  const arms = experiment.issues.map((issue) => assignedArm(experiment, experiment.repo, issue).name);
  assert.equal(arms.filter((name) => name === "luna-max").length, 2);
  assert.equal(arms.filter((name) => name === "terra-low").length, 2);
  assert.throws(() => validateExperiment({ ...experiment, issues: [12, 12] }), /invalid model A\/B/);
  assert.throws(() => validateExperiment({ ...experiment, ends_at: "2026-10-01T00:00:00Z" }), /72-hour/);
  assert.throws(() => validateExperiment({ ...experiment, arms: [{ ...experiment.arms[0] }] }), /invalid model A\/B/);
});

test("report keeps assigned denominators while counting fallback, escalation and accepted child work separately", () => {
  const summary = aggregateObserved({ repo: "example/repo", arms: {
    luna: { assigned: 2, issues: [12, 13] }, terra: { assigned: 1, issues: [14] },
  } }, (_repo, issue) => issue === 12
    ? { delivery: "verified", route_observed: true, models: ["openai/gpt-6-luna"],
      model_variants: ["openai/gpt-6-luna@max"], escalations: 2, fallbacks: 1,
      retries: 1, accepted_subagents: 1, parent_interventions: 0 }
    : { delivery: "pending", route_observed: false, models: [], model_variants: [],
      escalations: 0, fallbacks: 0, retries: 0, accepted_subagents: null, parent_interventions: null });
  assert.equal(summary.arms.luna.assigned, 2);
  assert.equal(summary.arms.luna.verified, 1);
  assert.equal(summary.arms.luna.pending, 1);
  assert.equal(summary.arms.luna.escalations, 2);
  assert.equal(summary.arms.luna.accepted_subagents, 1);
  assert.equal(summary.arms.luna.incomplete_evidence, 1);
  assert.equal(summary.arms.terra.pending, 1);
  assert.match(summary.result, /no automatic winner/);
});
