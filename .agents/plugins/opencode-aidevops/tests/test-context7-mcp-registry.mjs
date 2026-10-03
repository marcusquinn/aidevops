// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { applyAgentMcpTools } from "../agent-mcp-tools.mjs";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import { getOnDemandMcpAgents, registerMcpServers } from "../mcp-registry.mjs";

const AGENTS_DIR = fileURLToPath(new URL("../../..", import.meta.url));

test("Context7 stays disconnected at startup even when an old config enabled it", () => {
  const config = {
    mcp: { context7: { type: "remote", url: "https://mcp.context7.com/mcp", enabled: true } },
    tools: {},
  };
  registerMcpServers(config);

  assert.equal(config.mcp.context7.enabled, false);
  assert.equal(config.tools["context7_*"], false);
});

test("Context7 is on-demand via the bounded context7 agent", () => {
  const entry = getOnDemandMcpAgents().find((mcp) => mcp.name === "context7");
  assert.equal(entry?.agentName, "context7");
  assert.equal(entry.modelTier, "simple");

  const config = { agent: { build: { tools: {} } } };
  registerOnDemandMcpAgents(config, AGENTS_DIR);
  applyAgentMcpTools(config);

  assert.equal(config.agent.context7.tools["context7_*"], true);
  assert.equal(config.agent.context7.tools.aidevops_mcp, true);
  assert.equal(config.agent.build.tools["context7_*"], undefined);
  assert.match(config.agent.context7.prompt, /call aidevops_mcp with action "connect" and name "context7"/);
});
