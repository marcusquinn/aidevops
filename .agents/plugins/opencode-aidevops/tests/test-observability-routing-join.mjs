// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  consumeRoutingDecision,
  recordRoutingDecision as queueRoutingDecision,
} from "../observability-routing.mjs";

test("routing populations remain disjoint across execution contexts", () => {
  const previousHeadless = process.env.AIDEVOPS_HEADLESS;
  const previousTier = process.env.AIDEVOPS_DISPATCH_TIER;
  delete process.env.AIDEVOPS_HEADLESS;
  delete process.env.AIDEVOPS_DISPATCH_TIER;

  try {
    queueRoutingDecision("child-pop", {
      parentSessionID: "root",
      tier: "simple",
      reason: "agent_default",
    });
    assert.equal(consumeRoutingDecision({ sessionID: "child-pop" }).population, "interactive_child");

    queueRoutingDecision("root-pop", { tier: "standard", reason: "model_profile" });
    assert.equal(consumeRoutingDecision({ sessionID: "root-pop" }).population, "top_level_profile");

    queueRoutingDecision("compact-pop", { tier: "thinking", reason: "model_profile" });
    assert.equal(consumeRoutingDecision({
      sessionID: "compact-pop",
      summary: true,
      mode: "compaction",
    }).population, "compaction");

    process.env.AIDEVOPS_HEADLESS = "1";
    process.env.AIDEVOPS_DISPATCH_TIER = "thinking";
    assert.equal(consumeRoutingDecision({ sessionID: "headless-pop" }).population, "headless");
  } finally {
    if (previousHeadless === undefined) delete process.env.AIDEVOPS_HEADLESS;
    else process.env.AIDEVOPS_HEADLESS = previousHeadless;
    if (previousTier === undefined) delete process.env.AIDEVOPS_DISPATCH_TIER;
    else process.env.AIDEVOPS_DISPATCH_TIER = previousTier;
  }
});

test("completed child responses join queued routing decisions to parent feedback", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-routing-join-"));
  const previousHeadless = process.env.AIDEVOPS_HEADLESS;
  const previousTier = process.env.AIDEVOPS_DISPATCH_TIER;
  delete process.env.AIDEVOPS_HEADLESS;
  delete process.env.AIDEVOPS_DISPATCH_TIER;
  process.env.AIDEVOPS_OBS_DB_OVERRIDE = join(root, "llm-requests.db");
  const observability = await import(`../observability.mjs?routing-join=${Date.now()}`);
  const sqlite = await import("../../../scripts/sqlite-process.mjs");

  try {
    assert.equal(observability.initObservability({ aidevopsVersion: "3.32.240" }), true);
    observability.recordRoutingDecision("child-session", {
      parentSessionID: "root-session",
      tier: "simple",
      model: "openai/gpt-5.6-luna",
      variant: "max",
      requestedVariant: "xhigh",
      resolvedVariant: "max",
      candidateIndex: 0,
      attempt: 1,
      reason: "subagent_profile",
      escalated: false,
    });
    observability.handleEvent({
      event: {
        type: "message.updated",
        properties: {
          info: {
            id: "message-1",
            sessionID: "child-session",
            role: "assistant",
            providerID: "openai",
            modelID: "gpt-5.6-luna",
            variant: "max",
            finish: "stop",
            time: { created: 1000, completed: 1100 },
            tokens: { input: 10, output: 5, reasoning: 2, total: 17, cache: { read: 0, write: 0 } },
          },
        },
      },
    });

    const summary = observability.getRoutingFeedback("root-session");
    assert.equal(summary.requestCount, 1);
    assert.deepEqual(summary.tierPath, ["simple"]);
    assert.equal(summary.delegationCount, 1);
    assert.deepEqual(summary.delegationTiers, { simple: 1, standard: 0, thinking: 0 });
    assert.equal(summary.tokensTotal, 17);
    assert.equal(summary.models[0], "openai/gpt-5.6-luna");
    assert.deepEqual(summary.aidevopsVersions, ["3.32.240"]);
    assert.deepEqual(summary.pricingVersions, ["2026-09-05.1"]);
    assert.deepEqual(summary.populationsUsed, ["interactive_child"]);

    observability.recordSubagentOutcome({
      stage: "dispatch_requested",
      callID: "call-1",
      parentSessionID: "root-session",
    });
    observability.recordSubagentOutcome({
      stage: "host_outcome",
      callID: "call-1",
      parentSessionID: "root-session",
      childSessionID: "child-session",
      childSessionObserved: true,
      identityReason: "lifecycle",
      terminalEvidence: "stop",
      outcomeCategory: "host_completed",
      status: "completed",
      success: true,
    });
    observability.recordSubagentAcceptance({
      contributionID: "contribution:child",
      interventionCount: 1,
      objectiveID: "objective:1",
      outcome: "accepted_repaired",
      parentSessionID: "root-session",
      policyVersion: "v1",
      runID: "run:1",
    });
    await new Promise((resolve) => setTimeout(resolve, 100));

    const persisted = sqlite.sqliteExecSync(`
      SELECT routing_population || '|' || aidevops_version || '|' || pricing_version || '|'
        || requested_effort || '|' || resolved_effort || '|' || observed_effort || '|'
        || effort_source || '|' || coalesce(provider_confirmed_effort, '') || '|' || cost_source || '|'
        || pricing_quality
FROM llm_requests WHERE message_id = 'message-1';
    `);
    assert.equal(persisted, "interactive_child|3.32.240|2026-09-05.1|xhigh|max|max|host_observed||local_estimate|exact_model");

    const outcomePayload = JSON.parse(sqlite.sqliteExecSync(`
SELECT payload_json FROM runtime_events WHERE event_type = 'subagent.host.outcome' LIMIT 1;
    `));
    assert.equal(outcomePayload.outcome_category, "host_completed");
    assert.equal(outcomePayload.success, true);
    assert.deepEqual(JSON.parse(outcomePayload.observation), {
      child_session_observed: true,
      identity_reason: "lifecycle",
      rework: "unknown",
      semantic_acceptance: "unknown",
      terminal_evidence: "stop",
      verification: "unknown",
    });
    const acceptancePayload = JSON.parse(sqlite.sqliteExecSync(`
SELECT payload_json FROM runtime_events WHERE event_type = 'subagent.acceptance' LIMIT 1;
    `));
    assert.equal(acceptancePayload.contribution_outcome, "accepted_repaired");
    assert.equal(acceptancePayload.intervention_count, 1);
  } finally {
    sqlite.shutdownSqlite();
    delete process.env.AIDEVOPS_OBS_DB_OVERRIDE;
    if (previousHeadless === undefined) delete process.env.AIDEVOPS_HEADLESS;
    else process.env.AIDEVOPS_HEADLESS = previousHeadless;
    if (previousTier === undefined) delete process.env.AIDEVOPS_DISPATCH_TIER;
    else process.env.AIDEVOPS_DISPATCH_TIER = previousTier;
    rmSync(root, { recursive: true, force: true });
  }
});
