// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { applyAgentMcpTools } from "../agent-mcp-tools.mjs";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import { getOnDemandMcpAgents, registerMcpServers } from "../mcp-registry.mjs";

const agentsDir = fileURLToPath(new URL("../../..", import.meta.url));
const executeScript = "affinity-studio_execute_script";

test("Affinity registers a disabled loopback SSE server and tools", () => {
  const config = { mcp: {}, tools: {} };
  registerMcpServers(config);
  if (process.platform !== "darwin") {
    assert.equal(config.mcp["affinity-studio"], undefined);
    assert.equal(getOnDemandMcpAgents().some((entry) => entry.name === "affinity-studio"), false);
    return;
  }
  assert.deepEqual(config.mcp["affinity-studio"], {
    type: "remote", url: "http://[::1]:6767/sse", enabled: false,
  });
  assert.equal(config.tools["affinity-studio_*"], false);
  config.mcp["affinity-studio"].enabled = true;
  registerMcpServers(config);
  assert.equal(config.mcp["affinity-studio"].enabled, false);
});

test("only Affinity agent receives the full Affinity toolset without per-call prompts", { skip: process.platform !== "darwin" }, () => {
  const config = { agent: { build: { tools: {} } } };
  registerOnDemandMcpAgents(config, agentsDir);
  applyAgentMcpTools(config);
  const profile = config.agent.affinity;
  assert.equal(profile.tools.aidevops_mcp, true);
  assert.equal(profile.tools["*"], false);
  assert.equal(profile.permission["*"], "deny");
  for (const name of ["bash", "edit", "write", "task"]) {
    assert.equal(profile.tools[name], undefined);
  }
  // Affinity's in-app MCP toggles are the capability authority. A client-side
  // "ask" was silently auto-approved under the default `opencode --auto`
  // launcher (GH#32406), so the agent gets the whole toolset as plain allow.
  assert.equal(profile.tools["affinity-studio_*"], true);
  assert.equal(profile.permission["affinity-studio_*"], "allow");
  assert.equal(profile.tools[executeScript], undefined);
  assert.equal(profile.permission[executeScript], undefined);
  assert.ok(!Object.values(profile.permission).includes("ask"));
  assert.equal(config.agent.build.tools["affinity-studio_*"], undefined);
  assert.equal(config.agent.build.tools[executeScript], undefined);
  assert.equal(config.tools.aidevops_mcp, false);
  assert.doesNotMatch(profile.prompt, /per-call approval/);
  assert.match(profile.prompt, /without per-call prompts/);
  assert.match(profile.prompt, /active document path is the intended working copy/);

  // Re-registration keeps the wildcard grant.
  registerOnDemandMcpAgents(config, agentsDir);
  assert.equal(profile.tools["affinity-studio_*"], true);
  assert.equal(profile.permission["affinity-studio_*"], "allow");
});
