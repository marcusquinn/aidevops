// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { registerV2SubagentProfiles } from "../v2-subagent-profiles.mjs";

const AGENTS_DIR = new URL("../../../", import.meta.url).pathname;
const ROUTING = { specialistAdvisor: { model: "openai/gpt-6-astra", variant: "medium" } };

function editor(initial = []) {
  const agents = new Map(initial.map((agent) => [agent.id, agent]));
  return {
    agents,
    get: (id) => agents.get(id),
    update(id, change) {
      if (!agents.has(id)) agents.set(id, { id, mode: "subagent", hidden: false, permissions: [] });
      change(agents.get(id));
    },
  };
}

// Mirrors OpenCode V2 PermissionV2.evaluate: last matching rule wins, else "ask".
const match = (value, pattern) => new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")}$`).test(value);
const effect = (agent, action, resource = "x") =>
  agent.permissions.findLast((rule) => match(action, rule.action) && match(resource, rule.resource))?.effect ?? "ask";

const general = { id: "general", mode: "subagent", permissions: [{ action: "*", resource: "*", effect: "allow" }] };

test("V2 registers research-only, specialist-advisor and domain roles", () => {
  const host = editor([general]);
  assert.equal(registerV2SubagentProfiles(host, { agentsDir: AGENTS_DIR, routing: ROUTING, env: {} }), 4);
  for (const name of ["research-only", "specialist-advisor", "domain-focused", "domain-light"]) {
    const agent = host.get(name);
    assert.equal(agent.mode, "subagent", name);
    assert.equal(agent.hidden, false, name);
    assert.ok(agent.system && agent.description, name);
  }
});

test("V2 delegated agents cannot edit; inference-only roles deny everything", () => {
  const host = editor([general]);
  registerV2SubagentProfiles(host, { agentsDir: AGENTS_DIR, routing: ROUTING, env: {} });
  assert.equal(effect(host.get("research-only"), "edit"), "deny");
  assert.equal(effect(host.get("research-only"), "shell"), "deny");
  for (const name of ["specialist-advisor", "domain-focused", "domain-light"]) {
    assert.equal(effect(host.get(name), "read"), "deny", name);
    assert.equal(effect(host.get(name), "edit"), "deny", name);
  }
});

test("AI research ceiling makes research-only inference-only", () => {
  const host = editor([general]);
  registerV2SubagentProfiles(host, { agentsDir: AGENTS_DIR, env: { AIDEVOPS_AI_RESEARCH_TOOL_CEILING: "1" } });
  assert.equal(effect(host.get("research-only"), "read"), "deny");
  assert.equal(host.get("specialist-advisor"), undefined); // no routing, no adviser
});

test("V2 keeps operator agents and fails closed on a missing source", () => {
  const custom = { id: "research-only", mode: "subagent", system: "Operator", permissions: [] };
  const host = editor([general, custom]);
  registerV2SubagentProfiles(host, { agentsDir: AGENTS_DIR, env: {} });
  assert.equal(host.get("research-only"), custom);
  const empty = editor([general]);
  registerV2SubagentProfiles(empty, { agentsDir: "/nonexistent-aidevops-agents", routing: ROUTING, env: {} });
  assert.equal(empty.get("research-only"), undefined);
  assert.equal(empty.get("specialist-advisor"), undefined);
});
