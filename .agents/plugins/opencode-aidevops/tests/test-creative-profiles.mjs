// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { registerMcpServers, getOnDemandMcpAgents } from "../mcp-registry.mjs";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import { createSubagentEffortHooks } from "../subagent-effort.mjs";

const agentsDir = fileURLToPath(new URL("../../..", import.meta.url));
const creativeNames = ["blender", "freecad", "ableton", "davinci-resolve"];

function fixture({ variant = "high", pinned = false } = {}) {
  const state = { tiers: new Map(), pinned: new Set() };
  const config = { agent: pinned ? { freecad: { model: "other/pinned", variant: "low" } } : {} };
  const routing = { tiers: { standard: { candidates: ["openai/cheap"] } } };
  registerOnDemandMcpAgents(config, agentsDir, routing, state);
  const client = { session: {
    get: async ({ path }) => ({ data: path.id === "parent"
      ? { model: { providerID: "openai", modelID: "creative" }, variant }
      : { id: path.id, parentID: "parent" } }),
    messages: async () => ({ data: [] }),
  } };
  const hooks = createSubagentEffortHooks(client, {
    agentRoutingState: state, modelRouting: routing,
    tierReasoning: { standard: { openai: "low" } },
  });
  return { config, state, hooks };
}

test("creative MCPs stay disconnected and have no unrelated tools or recursive tasks", () => {
  const { config, state } = fixture();
  registerMcpServers(config);
  assert.deepEqual([...state.inheritParentRoute], creativeNames);
  for (const name of creativeNames) {
    const entry = getOnDemandMcpAgents().find((item) => item.agentName === name);
    assert.equal(config.mcp[entry.name].enabled, false);
    assert.equal(config.tools[entry.toolPattern], false);
    assert.equal(config.agent[name].tools["*"], false);
    assert.equal(config.agent[name].permission["*"], "deny");
    assert.equal(config.agent[name].tools[entry.toolPattern], true);
    assert.doesNotMatch(config.agent[name].prompt, /# Build\+|# Content - Multi-Media/);
  }
  assert.equal(registerOnDemandMcpAgents(config, agentsDir, { tiers: {} }, state), 0);
});

test("creative child inherits the exact parent model/effort without changing the supplied brief", async () => {
  const { hooks } = fixture();
  const output = { message: { sessionID: "child", agent: "freecad" },
    parts: [{ type: "text", text: "[effort:standard] Build only the approved cabinet copy" }] };
  await hooks.chatMessage({}, output);
  assert.deepEqual(output.message.model, { providerID: "openai", modelID: "creative" });
  assert.equal(output.parts.length, 1);
  assert.equal(output.parts[0].text, "[effort:standard] Build only the approved cabinet copy");
  const params = { options: { reasoning_effort: "low" } };
  await hooks.chatParams({ message: output.message, model: output.message.model }, params);
  assert.deepEqual(params.options, { reasoning_effort: "high", reasoningEffort: "high" });
  await assert.rejects(hooks.chatParams({ message: output.message,
    model: { providerID: "openai", modelID: "changed" } }, params), /model changed/);
});

test("unknown creative parent and a missing routing policy fail closed", async () => {
  const { hooks } = fixture({ variant: "" });
  const message = { sessionID: "child", agent: "ableton" };
  await assert.rejects(hooks.chatMessage({}, { message, parts: [{ type: "text", text: "Edit copy" }] }), /unavailable/);
  await assert.rejects(hooks.chatParams({ message,
    model: { providerID: "openai", modelID: "creative" } }, { options: {} }), /unavailable/);
});

test("an explicit creative child pin retains its native model and variant", async () => {
  const { hooks, config } = fixture({ pinned: true });
  const output = { message: { sessionID: "child", agent: "freecad", model: { providerID: "other", modelID: "pinned" } },
    parts: [{ type: "text", text: "Edit only the approved copy" }] };
  await hooks.chatMessage({}, output);
  const params = { options: { reasoningEffort: "low" } };
  await hooks.chatParams({ message: output.message, model: output.message.model }, params);
  assert.deepEqual(output.message.model, { providerID: "other", modelID: "pinned" });
  assert.equal(config.agent.freecad.variant, "low");
  assert.deepEqual(params.options, { reasoningEffort: "low" });
});
