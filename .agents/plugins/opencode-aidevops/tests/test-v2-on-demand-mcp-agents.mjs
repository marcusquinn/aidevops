// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { getOnDemandMcpAgents, registerMcpServers } from "../mcp-registry.mjs";
import { registerV2OnDemandMcpAgents } from "../v2-on-demand-mcp-agents.mjs";

const AGENTS_DIR = new URL("../../../", import.meta.url).pathname;

function editor(initial = []) {
  const agents = new Map(initial.map((agent) => [agent.id, agent]));
  return {
    agents,
    list: () => [...agents.values()],
    get: (id) => agents.get(id),
    update(id, change) {
      if (!agents.has(id)) agents.set(id, { id, mode: "subagent", hidden: false, permissions: [] });
      change(agents.get(id));
    },
  };
}

// Mirrors OpenCode V2 PermissionV2.evaluate: last matching rule wins, else "ask".
const match = (value, pattern) => new RegExp(`^${pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")}$`).test(value);
function effect(agent, action, resource = "x") {
  return agent.permissions.findLast((rule) => match(action, rule.action) && match(resource, rule.resource))?.effect ?? "ask";
}

function setup(initial) {
  const tools = {};
  registerMcpServers({ mcp: {}, tools }, { runtime: { platform: process.platform } });
  const host = editor(initial ?? [
    { id: "general", mode: "subagent", permissions: [{ action: "*", resource: "*", effect: "allow" }] },
    { id: "Build+", mode: "primary", permissions: [{ action: "*", resource: "*", effect: "allow" }] },
  ]);
  const created = registerV2OnDemandMcpAgents(host, { agentsDir: AGENTS_DIR, toolPolicy: tools });
  return { host, created, tools };
}

test("V2 registers every on-demand MCP activation agent with its activation prompt", () => {
  const { host, created } = setup();
  const mcps = getOnDemandMcpAgents();
  assert.equal(created, mcps.length);
  for (const mcp of mcps) {
    const agent = host.get(mcp.agentName);
    assert.equal(agent.mode, "subagent", mcp.agentName);
    assert.match(agent.system, new RegExp(`name \\"${mcp.name}\\"`));
    assert.equal(effect(agent, "aidevops_mcp"), "allow", mcp.agentName);
  }
  // GH#34219 reproducer: the activation tool requires the caller to be the
  // registry's activation agent, which must now exist and be selectable.
  const seoUtils = mcps.find((mcp) => mcp.name === "seo-utils");
  assert.equal(host.get(seoUtils.agentName).hidden, false);
  assert.equal(effect(host.get(seoUtils.agentName), "seo-utils_query"), "allow");
  assert.equal(effect(host.get("Build+"), "seo-utils_query"), "deny");
});

test("V2 scopes MCP tools and activation to the owning agent", () => {
  const { host } = setup();
  const build = host.get("Build+");
  assert.equal(effect(build, "aidevops_mcp"), "deny");
  assert.equal(effect(build, "context7_resolve-library-id"), "deny");
  assert.equal(effect(build, "read"), "allow");
  const context7 = host.get("context7");
  assert.equal(effect(context7, "context7_resolve-library-id"), "allow");
  assert.equal(effect(context7, "sentry_search_issues"), "deny");
  assert.equal(effect(context7, "bash"), "deny");
  assert.equal(effect(context7, "edit"), "deny");
});

test("V2 activation agents keep authored restrictions and exact tool allowlists", () => {
  const { host } = setup();
  const blender = host.get("blender");
  assert.equal(effect(blender, "bash"), "deny");
  assert.equal(effect(blender, "glob"), "deny");
  assert.equal(effect(blender, "grep"), "allow");
  assert.equal(effect(blender, "blender-lab_execute"), "allow");
  const mobile = getOnDemandMcpAgents().find((mcp) => mcp.allowedTools);
  const agent = host.get(mobile.agentName);
  assert.equal(effect(agent, mobile.allowedTools[0]), mobile.approvalRequiredTools?.includes(mobile.allowedTools[0]) ? "ask" : "allow");
  assert.equal(effect(agent, `${mobile.toolPattern.slice(0, -1)}unlisted_tool`), "deny");
});

test("V2 operator activation agents keep their prompt and explicit activation rule", () => {
  const operator = {
    id: "context7", mode: "subagent", system: "Operator prompt",
    permissions: [{ action: "aidevops_mcp", resource: "*", effect: "ask" }],
  };
  const { host, created } = setup([operator]);
  assert.equal(created, getOnDemandMcpAgents().length - 1);
  assert.equal(host.get("context7").system, "Operator prompt");
  assert.equal(effect(host.get("context7"), "aidevops_mcp"), "ask");
  assert.equal(effect(host.get("context7"), "context7_query-docs"), "allow");
});
