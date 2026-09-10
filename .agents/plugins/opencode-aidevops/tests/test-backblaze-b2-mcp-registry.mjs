// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { homedir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { applyAgentMcpTools } from "../agent-mcp-tools.mjs";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import { createMcpActivationTool } from "../mcp-activation-tool.mjs";
import { getOnDemandMcpAgents, registerMcpServers } from "../mcp-registry.mjs";

test("Backblaze B2 stays disabled globally and preserves custom configuration", () => {
  const config = { mcp: {}, tools: {} };
  registerMcpServers(config);
  assert.deepEqual(config.mcp["backblaze-b2"], {
    type: "local",
    command: [join(homedir(), ".aidevops", "agents", "scripts", "backblaze-b2-mcp-launcher.sh")],
    enabled: false,
  });
  assert.equal(config.tools["backblaze-b2_*"], false);

  const custom = {
    mcp: { "backblaze-b2": { type: "local", command: ["custom-b2-mcp"], enabled: true } },
    tools: { "backblaze-b2_*": true },
  };
  registerMcpServers(custom);
  assert.deepEqual(custom.mcp["backblaze-b2"].command, ["custom-b2-mcp"]);
  assert.equal(custom.mcp["backblaze-b2"].enabled, false);
  assert.equal(custom.tools["backblaze-b2_*"], false);
});

test("only the bounded Backblaze B2 agent gets B2 tools", () => {
  const config = { agent: { build: { tools: {} } } };
  registerOnDemandMcpAgents(config, fileURLToPath(new URL("../../..", import.meta.url)));
  applyAgentMcpTools(config);
  assert.equal(config.agent["backblaze-b2"].tools["backblaze-b2_*"], true);
  assert.equal(config.agent["backblaze-b2"].tools.aidevops_mcp, true);
  assert.equal(config.agent.build.tools["backblaze-b2_*"], undefined);
  assert.equal(config.tools.aidevops_mcp, false);
});

test("Backblaze B2 is allowlisted for explicit connect and disconnect", async () => {
  const calls = [];
  const schema = { describe() { return this; } };
  const activation = createMcpActivationTool((definition) => definition, {
    enum() { return schema; },
  }, {
    allowedNames: getOnDemandMcpAgents().map((entry) => entry.name),
    client: {
      async connect(request) { calls.push(["connect", request.path.name]); return {}; },
      async disconnect(request) { calls.push(["disconnect", request.path.name]); return {}; },
      async status() { return { data: { "backblaze-b2": { status: "connected" } } }; },
    },
  });
  assert.match(await activation.execute({ action: "connect", name: "backblaze-b2" }), /Connected MCP/);
  assert.match(await activation.execute({ action: "disconnect", name: "backblaze-b2" }), /Disconnected MCP/);
  assert.deepEqual(calls, [["connect", "backblaze-b2"], ["disconnect", "backblaze-b2"]]);
});
