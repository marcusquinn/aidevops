// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { applyAgentMcpTools } from "../agent-mcp-tools.mjs";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import { getOnDemandMcpAgents, registerMcpServers } from "../mcp-registry.mjs";

const agentsDir = fileURLToPath(new URL("../../..", import.meta.url));
const allowed = [
  "affinity-studio_list_sdk_documentation",
  "affinity-studio_read_sdk_documentation_topic",
  "affinity-studio_render_selection",
  "affinity-studio_render_spread",
];
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

test("only Affinity agent receives read tools and per-call-approved script execution", { skip: process.platform !== "darwin" }, () => {
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
  assert.equal(profile.tools["affinity-studio_*"], false);
  assert.equal(profile.permission["affinity-studio_*"], "deny");
  for (const name of allowed) {
    assert.equal(profile.tools[name], true);
    assert.equal(profile.permission[name], "allow");
  }
  assert.equal(profile.tools[executeScript], true);
  assert.equal(profile.permission[executeScript], "ask");
  for (const name of [
    "affinity-studio_save_script_to_library",
    "affinity-studio_read_library_script", "affinity-studio_add_sdk_hint",
  ]) {
    assert.equal(profile.tools[name], undefined);
    assert.equal(profile.permission[name], undefined);
  }
  assert.equal(config.agent.build.tools["affinity-studio_*"], undefined);
  assert.equal(config.agent.build.tools[executeScript], undefined);
  assert.equal(config.tools.aidevops_mcp, false);
  assert.match(profile.prompt, /execute_script requires per-call approval/);
  assert.match(profile.prompt, /active document path is the approved isolated copy/);

  // Re-registration must not turn the wildcard back on, including after a stale config.
  profile.tools["affinity-studio_*"] = true;
  profile.permission["affinity-studio_*"] = "allow";
  profile.permission[executeScript] = "allow";
  registerOnDemandMcpAgents(config, agentsDir);
  assert.equal(profile.tools["affinity-studio_*"], false);
  assert.equal(profile.permission["affinity-studio_*"], "deny");
  assert.equal(profile.permission[executeScript], "ask");
});
