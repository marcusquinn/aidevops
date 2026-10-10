// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#32592: rarely used V1 plugin tools sit behind one compact dispatcher.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { createPoolTool } from "../oauth-pool-tool.mjs";
import { createObjectiveReceiptTool } from "../objective-receipt-tool.mjs";
import {
  ON_DEMAND_TOOL,
  ON_DEMAND_TOOL_NAMES,
  createOnDemandTool,
  moveToolsOnDemand,
} from "../on-demand-tools.mjs";
import { tool } from "../tool-schema.mjs";
import { createTools } from "../tools.mjs";

const z = tool.schema;
// CI installs plugin dependencies, so the host Zod helper resolves there.
const hasZod = typeof z.strictObject === "function" && typeof z.toJSONSchema === "function";
const zodSkip = hasZod ? false : "@opencode-ai/plugin Zod helper unavailable (no plugin node_modules)";

function poolStub(calls) {
  return tool({
    description: "Manage OAuth account pool for provider credential rotation. Long detail that stays out of the summary.",
    args: {
      action: z.enum(["list", "rotate"]).describe("Action to perform"),
      provider: z.enum(["anthropic", "openai"]).optional().describe("Provider"),
    },
    async execute(args, context) {
      calls.push({ args, context });
      return `pool ${args.action}`;
    },
  });
}

function baseTools(calls, decisions) {
  return {
    aidevops_memory: { description: "memory", args: {}, execute: async () => "memory" },
    "model-accounts-pool": poolStub(calls),
    aidevops_mcp: { description: "gated MCP lifecycle", args: {}, execute: async () => "mcp" },
    aidevops_objective_receipt: createObjectiveReceiptTool(tool, (decision) => {
      decisions.push(decision);
      return "recorded";
    }),
  };
}

test("rare tools move behind one dispatcher; gated and frequent tools stay direct", () => {
  const tools = moveToolsOnDemand(baseTools([], []), tool);
  assert.deepEqual(Object.keys(tools), ["aidevops_memory", "aidevops_mcp", ON_DEMAND_TOOL]);
  assert.deepEqual(
    [...ON_DEMAND_TOOL_NAMES].sort(),
    ["aidevops_objective_receipt", "gpt_image_generate", "model-accounts-pool"],
  );
  const empty = moveToolsOnDemand({ aidevops_memory: {} }, tool);
  assert.deepEqual(Object.keys(empty), ["aidevops_memory"], "no dispatcher without sub-tools");
});

test("the V1 entrypoint applies the dispatcher and V2 keeps Code Mode deferral", () => {
  const read = (file) => readFileSync(new URL(`../${file}`, import.meta.url), "utf8");
  assert.match(read("index.mjs"), /moveToolsOnDemand\(tools, tool\)/);
  assert.doesNotMatch(read("v2.mjs"), /moveToolsOnDemand/);
});

test("description lists one-line signatures and first-sentence summaries", { skip: zodSkip }, () => {
  const dispatcher = moveToolsOnDemand(baseTools([], []), tool)[ON_DEMAND_TOOL];
  assert.match(
    dispatcher.description,
    /^- model-accounts-pool\(action: list\|rotate, provider\?\): Manage OAuth account pool for provider credential rotation\.$/m,
  );
  assert.match(dispatcher.description, /^- aidevops_objective_receipt\(parent_session_id\?, .*policy_version\?\): Record an explicit/m);
  assert.doesNotMatch(dispatcher.description, /Long detail/);
  assert.match(dispatcher.description, /Omit args to get its full schema/);
});

test("omitted args return the full schema without executing", { skip: zodSkip }, async () => {
  const calls = [];
  const decisions = [];
  const dispatcher = moveToolsOnDemand(baseTools(calls, decisions), tool)[ON_DEMAND_TOOL];
  const schema = await dispatcher.execute({ tool: "aidevops_objective_receipt" }, {});
  assert.match(schema, /aidevops_objective_receipt: Record an explicit parent acceptance/);
  assert.match(schema, /"objective_outcome":\{"type":"string","enum":\["verified"/);
  assert.equal(decisions.length, 0, "describe mode must never record a receipt");
  assert.equal(calls.length, 0);
});

test("invalid args return issues plus the full schema", { skip: zodSkip }, async () => {
  const calls = [];
  const dispatcher = createOnDemandTool(tool, { "model-accounts-pool": poolStub(calls) });
  await assert.rejects(
    dispatcher.execute({ tool: "model-accounts-pool", args: { action: "explode", emial: "x" } }, {}),
    (error) => {
      assert.match(error.message, /Invalid args for model-accounts-pool: action: .*; args: Unrecognized key/);
      assert.match(error.message, /args JSON schema: \{"type":"object","properties":\{"action"/);
      assert.match(error.message, /Action to perform/);
      return true;
    },
  );
  await assert.rejects(dispatcher.execute({ tool: "model-accounts-pool", args: ["list"] }, {}), /args must be an object/);
  await assert.rejects(dispatcher.execute({ tool: "missing", args: {} }, {}), /Unknown on-demand tool "missing"\. Available: model-accounts-pool\./);
  assert.equal(calls.length, 0);
});

test("valid args execute the sub-tool with context and without nested intent", { skip: zodSkip }, async () => {
  const calls = [];
  const decisions = [];
  const dispatcher = moveToolsOnDemand(baseTools(calls, decisions), tool)[ON_DEMAND_TOOL];
  const context = { sessionID: "ses_1", agent: "Build+" };
  const result = await dispatcher.execute({
    tool: "model-accounts-pool",
    args: { action: "list", provider: "openai", agent__intent: "Listing accounts" },
  }, context);
  assert.equal(result, "pool list");
  assert.deepEqual(calls, [{ args: { action: "list", provider: "openai" }, context }]);

  assert.equal(await dispatcher.execute({
    tool: "aidevops_objective_receipt",
    args: { parent_session_id: "ses_1", objective_id: "objective:root", run_id: "run:root", contribution_id: "opencode-child:child", outcome: "accepted_unchanged" },
  }, context), "recorded");
  assert.equal(decisions[0].objectiveID, "objective:root");
  assert.equal(decisions[0].outcome, "accepted_unchanged");
});

test("parent-receipt hint args return host-compatible text and reject missing identity", { skip: zodSkip }, async () => {
  const decisions = [];
  const receipt = createObjectiveReceiptTool(tool, (decision) => {
    decisions.push(decision);
    return { recorded: true, objectiveID: decision.objectiveID };
  });
  const dispatcher = createOnDemandTool(tool, { aidevops_objective_receipt: receipt });
  const args = {
    parent_session_id: "parent", objective_id: "objective:root", run_id: "run:root",
    contribution_id: "opencode-child:child-objective", outcome: "accepted_unchanged",
  };
  const invoke = (input) => dispatcher.execute({ tool: "aidevops_objective_receipt", args: input }, {});
  assert.deepEqual(JSON.parse(await invoke(args)), { recorded: true, objectiveID: "objective:root" });
  assert.equal(decisions[0].repairContributionID, undefined);
  assert.equal(decisions[0].policyVersion, "v1");
  assert.deepEqual(JSON.parse(await invoke({
    ...args, objective_outcome: "verified", evidence_kind: "release-tag",
    evidence_fingerprint: "v3.37.14", observer: "parent",
  })), { recorded: true, objectiveID: "objective:root" });
  await assert.rejects(invoke({ ...args, contribution_id: "" }), /requires contribution_id/);
  assert.equal(decisions.length, 2);
});

test("dispatcher stays compact relative to the production tools it replaces", { skip: zodSkip }, () => {
  const tools = createTools("/tmp/aidevops-test-scripts", () => "", {
    poolToolFactory: () => createPoolTool({}),
  });
  tools.aidevops_objective_receipt = createObjectiveReceiptTool(tool, () => "recorded");
  const wireSize = (definition) => definition.description.length
    + JSON.stringify(z.toJSONSchema(z.object(definition.args))).length;
  const replaced = ON_DEMAND_TOOL_NAMES
    .map((name) => wireSize(tools[name]))
    .reduce((sum, size) => sum + size, 0);
  const size = wireSize(moveToolsOnDemand(tools, tool)[ON_DEMAND_TOOL]);
  // Measured 1,213 vs 3,414 chars when introduced; keep the saving material.
  assert.ok(size < replaced * 0.45, `dispatcher ${size} chars should be well under replaced ${replaced} chars`);
});

test("without Zod the dispatcher passes object args through", async () => {
  const node = { optional() { return this; }, describe() { return this; } };
  const fallbackTool = (definition) => definition;
  fallbackTool.schema = { enum: () => node, string: () => node };
  const seen = [];
  const dispatcher = createOnDemandTool(fallbackTool, {
    sample: { description: "Sample tool. More.", args: { a: node }, execute: async (args) => { seen.push(args); return "ok"; } },
  });
  assert.match(dispatcher.description, /^- sample\(a\): Sample tool\.$/m);
  assert.equal(await dispatcher.execute({ tool: "sample", args: { a: 1, agent__intent: "x" } }, {}), "ok");
  assert.deepEqual(seen, [{ a: 1 }]);
  assert.match(await dispatcher.execute({ tool: "sample" }, {}), /sample: Sample tool\. More\.\nargs JSON schema: \{a\}/);
});
