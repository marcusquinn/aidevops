// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { loadModelRouting, mergeModelRouting, nextRoutingTier, routingProfile } from "../model-routing.mjs";
import { registerAgents } from "../config-agent-profiles.mjs";
import { createSubagentEffortHooks, loadTierReasoningPolicies } from "../subagent-effort.mjs";
import { registerSpecialistAdvisor, validateSpecialistRequest, applyDailyDriverDefaults } from "../specialist-advisor.mjs";

const agentsDir = fileURLToPath(new URL("../../../", import.meta.url));
const table = fileURLToPath(new URL("../../../configs/model-routing-table.json", import.meta.url));
const routing = loadModelRouting([table]);
const agentRoutingPolicy = readFileSync(new URL("../../../reference/agent-routing.md", import.meta.url), "utf8");
const selfImprovementPolicy = readFileSync(new URL("../../../reference/self-improvement.md", import.meta.url), "utf8");
const workerProtocol = readFileSync(new URL("../../../prompts/worker-efficiency-protocol.md", import.meta.url), "utf8");
const envelope = JSON.stringify({
  objective: "Resolve a supplied ordering failure", scope: "Advice only; no tools",
  evidence: "Two concurrent updates overwrite each other; current check fails",
  escalation_reason: "Cheaper analysis did not resolve the supplied failing interleaving",
  output: "Propose an invariant and parent-verifiable check",
});

test("shipped routes keep Luna-first simple, Anthropic-primary standard/thinking, and Astra outside automatic escalation", () => {
  assert.deepEqual(routingProfile(routing, "simple"), { tier: "simple", model: "openai/gpt-6-luna", variant: "high" });
  assert.deepEqual(routingProfile(routing, "standard"), { tier: "standard", model: "anthropic/claude-sonnet-5-5", variant: "medium" });
  assert.deepEqual(routingProfile(routing, "thinking"), { tier: "thinking", model: "anthropic/claude-opus-5-5", variant: "high" });
  assert.equal(nextRoutingTier(routing, "thinking"), "");
  assert.deepEqual(routing.specialistAdvisor, { model: "openai/gpt-6-astra", variant: "medium" });
  assert.equal(mergeModelRouting(routing, { specialist_advisor: null }).specialistAdvisor, null);
  assert.equal(mergeModelRouting(routing, { specialist_advisor: { model: "invalid", variant: "low" } }).specialistAdvisor, null);
  assert.deepEqual(mergeModelRouting(routing, { tiers: {} }).specialistAdvisor, routing.specialistAdvisor);
  const partial = mergeModelRouting(routing, { tiers: { standard: { models: ["openai/gpt-6.1-terra"], reasoning: {} } } });
  assert.deepEqual(routingProfile(partial, "standard"), {
    tier: "standard", model: "openai/gpt-6.1-terra", variant: "medium",
  });
  assert.deepEqual(routingProfile(routing, "simple"), { tier: "simple", model: "openai/gpt-6-luna", variant: "high" });
});

test("policy requires one bounded highest-capability consultation before an avoidable user decision", () => {
  assert.match(agentRoutingPolicy, /highest-\s*capability configured and authorized advisory route/);
  assert.match(agentRoutingPolicy, /validates the result once/);
  assert.match(selfImprovementPolicy, /highest configured and authorized capable advisory route\s+once/);
  assert.match(workerProtocol, /consult the highest configured and\s+authorized capable advisory route once/);
  assert.match(workerProtocol, /do not repeat an unchanged\s+consultation/);
});

test("decision advice preserves human, route, and failure boundaries", () => {
  assert.match(agentRoutingPolicy, /Advice cannot supply authority, consent, taste or values/);
  assert.match(agentRoutingPolicy, /missing\/disabled profile is\s+unavailable; never silently switch providers/);
  assert.match(workerProtocol, /privacy\/locality, billing and explicit model\s+pins outside model escalation/);
  assert.match(workerProtocol, /provider, authentication, rate-limit or tool failures use their own recovery path/);
});

test("registration supplies canonical tool-free adviser and defaults without replacing user pins", () => {
  const state = { tiers: new Map(), pinned: new Set() };
  const config = { agent: { "Build+": { mode: "primary" } } };
  registerAgents(config, agentsDir, routing, state);
  assert.equal(config.model, "anthropic/claude-opus-5-5");
  assert.equal(config.agent["Build+"].variant, "high");
  const advisor = config.agent["specialist-advisor"];
  assert.equal(advisor.model, "openai/gpt-6-astra");
  assert.equal(advisor.variant, "medium");
  assert.deepEqual(advisor.tools, { "*": false });
  assert.deepEqual(advisor.permission, { "*": "deny" });
  assert.match(advisor.prompt, /no tools, network, credentials/);
  assert.ok(state.pinned.has("specialist-advisor"));
  assert.equal(registerSpecialistAdvisor(config, agentsDir, routing, state), 0);
  const custom = { model: "other/model", agent: {
    "Build+": { mode: "primary", variant: "high" },
    "specialist-advisor": { disable: true },
  } };
  const before = structuredClone(custom);
  applyDailyDriverDefaults(custom, routing);
  registerSpecialistAdvisor(custom, agentsDir, routing, state);
  assert.deepEqual(custom, before);
  assert.equal(registerSpecialistAdvisor({ agent: {} }, "/nonexistent", routing, state), 0);
});

test("local interactive default can use medium while the thinking tier stays xhigh", () => {
  const customized = mergeModelRouting(routing, {
    interactive_default: { model: "anthropic/claude-opus-5-5", variant: "medium" },
    tiers: { thinking: {
      models: ["anthropic/claude-opus-5-5", "openai/gpt-6-sol"],
      reasoning: { "anthropic/claude-opus-5-5": "xhigh" },
    } },
  });
  const config = { agent: { "Build+": { mode: "primary" } } };
  applyDailyDriverDefaults(config, customized);
  assert.equal(config.model, "anthropic/claude-opus-5-5");
  assert.equal(config.agent["Build+"].variant, "medium");
  assert.deepEqual(routingProfile(customized, "thinking"), {
    tier: "thinking", model: "anthropic/claude-opus-5-5", variant: "xhigh",
  });

  const pinned = { model: "openai/gpt-6-sol", agent: { "Build+": { mode: "primary", variant: "high" } } };
  applyDailyDriverDefaults(pinned, customized);
  assert.deepEqual(pinned, { model: "openai/gpt-6-sol", agent: { "Build+": { mode: "primary", variant: "high" } } });
  assert.equal(mergeModelRouting(customized, { interactive_default: null }).interactiveDefault, null);
  assert.equal(mergeModelRouting(customized, { interactive_default: { model: "invalid", variant: "medium" } }).interactiveDefault, null);
});

test("specialist request requires evidence and an explicit escalation reason", () => {
  assert.doesNotThrow(() => validateSpecialistRequest(`[effort:thinking] ${envelope}`));
  assert.throws(() => validateSpecialistRequest("audit everything"), /JSON evidence envelope/);
  const invalid = JSON.parse(envelope);
  delete invalid.escalation_reason;
  assert.throws(() => validateSpecialistRequest(JSON.stringify(invalid)), /escalation_reason/);
  assert.throws(() => validateSpecialistRequest("null"), /requires objective/);
});

test("unreadable provider state reports a read failure without substituting the specialist", async () => {
  const state = { tiers: new Map(), pinned: new Set() };
  registerAgents({ agent: {} }, agentsDir, routing, state);
  for (const client of [{}, { provider: { list: async () => { throw new Error("offline"); } } }]) {
    const hooks = createSubagentEffortHooks(client, {
      modelRouting: routing, agentRoutingState: state,
    });
    const output = {
      message: { sessionID: "child", agent: "specialist-advisor",
        model: { providerID: "openai", modelID: "gpt-6-astra" } },
      parts: [{ type: "text", text: envelope }],
    };
    await assert.rejects(hooks.chatMessage({}, output),
      /Specialist advisory route unavailable: unable to read provider state for openai\/gpt-6-astra.*No automatic substitute/);
    assert.equal(output.message.model.modelID, "gpt-6-astra");
  }
});

test("Sol parent can explicitly request Astra advice in interactive and headless hooks", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "advisor-auth-"));
  const previous = process.env.XDG_DATA_HOME;
  process.env.XDG_DATA_HOME = root;
  t.after(() => {
    if (previous === undefined) delete process.env.XDG_DATA_HOME;
    else process.env.XDG_DATA_HOME = previous;
    rmSync(root, { recursive: true, force: true });
  });
  mkdirSync(join(root, "opencode"));
  const authPath = join(root, "opencode", "auth.json");
  const providers = { connected: ["openai"], all: [{ id: "openai", models: {
    "gpt-6-astra": { id: "gpt-6-astra" }, "gpt-6.1-sol": { id: "gpt-6.1-sol" },
  } }] };
  for (const isHeadless of [false, true]) {
    writeFileSync(authPath, JSON.stringify({ openai: { type: "api", key: "test-only" } }));
    const state = { tiers: new Map(), pinned: new Set() };
    const config = { agent: {} };
    registerAgents(config, agentsDir, routing, state);
    const client = { provider: { list: async () => ({ data: providers }) }, session: {
      get: async ({ path }) => ({ data: path.id === "child"
        ? { id: "child", parentID: "parent" }
        : { id: "parent", model: { providerID: "openai", modelID: "gpt-5.6-sol" }, variant: "medium" } }),
    } };
    const hooks = createSubagentEffortHooks(client, {
      modelRouting: routing, tierReasoning: loadTierReasoningPolicies([table]), agentRoutingState: state,
      isHeadless: () => isHeadless,
    });
    const output = {
      message: { sessionID: "child", agent: "specialist-advisor", variant: "low",
        model: { providerID: "openai", modelID: "gpt-6-astra" } },
      parts: [{ type: "text", text: envelope }],
    };
    await hooks.chatMessage({}, output);
    assert.equal(output.message.model.modelID, "gpt-6-astra");
    const params = { options: {} };
    await hooks.chatParams({ message: output.message, provider: { id: "openai" }, model: { id: "gpt-6-astra" } }, params);
    assert.equal(params.options.reasoningEffort, "medium");
    writeFileSync(authPath, JSON.stringify({ openai: { type: "oauth", access: "test-only" } }));
    await assert.rejects(hooks.chatMessage({}, output), /Specialist advisory route unavailable.*No automatic substitute/);
    assert.equal(output.message.model.modelID, "gpt-6-astra");
    const research = { message: { sessionID: "child", agent: "research-only" },
      parts: [{ type: "text", text: "[effort:standard] Read README.md and return its first heading" }] };
    await assert.rejects(hooks.chatMessage({}, research), /No connected model is available/);
    writeFileSync(authPath, JSON.stringify({ openai: { type: "api", key: "test-only" } }));
    await hooks.chatMessage({}, research);
    assert.equal(research.message.model.modelID, "gpt-6.1-sol");
    output.parts[0].text = "Use Astra for no stated reason";
    await assert.rejects(hooks.chatMessage({}, output), /JSON evidence envelope/);
  }
});
