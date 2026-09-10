// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { applyAgentMcpTools } from "../agent-mcp-tools.mjs";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import { createMcpActivationTool } from "../mcp-activation-tool.mjs";
import { getOnDemandMcpAgents, registerMcpServers } from "../mcp-registry.mjs";

const AGENTS_DIR = fileURLToPath(new URL("../../..", import.meta.url));

test("PostHog registers as a disabled hosted MCP", () => {
  const config = { mcp: {}, tools: {} };
  registerMcpServers(config);

  assert.deepEqual(config.mcp.posthog, {
    type: "remote",
    url: "https://mcp.posthog.com/mcp",
    enabled: false,
  });
  assert.equal(config.tools["posthog_*"], false);
});

test("PostHog preserves a custom least-privilege URL but keeps it disconnected", () => {
  const config = {
    mcp: {
      posthog: {
        type: "remote",
        url: "https://mcp.posthog.com/mcp?readonly=true&project_id=fixture",
        enabled: true,
      },
    },
    tools: { "posthog_*": true },
  };

  registerMcpServers(config);

  assert.equal(config.mcp.posthog.url, "https://mcp.posthog.com/mcp?readonly=true&project_id=fixture");
  assert.equal(config.mcp.posthog.enabled, false);
  assert.equal(config.tools["posthog_*"], false);
});

test("only the bounded PostHog agent gets PostHog tools", () => {
  const config = { agent: { build: { tools: {} } } };
  registerOnDemandMcpAgents(config, AGENTS_DIR);
  applyAgentMcpTools(config);

  assert.equal(config.agent.posthog.tools["posthog_*"], true);
  assert.equal(config.agent.posthog.tools.aidevops_mcp, true);
  assert.equal(config.agent.build.tools["posthog_*"], undefined);
  assert.equal(config.tools.aidevops_mcp, false);
  assert.match(config.agent.posthog.prompt, /Confirm the authenticated PostHog organization and project/);
  assert.match(config.agent.posthog.prompt, /may incur PostHog AI spend/);
});

test("PostHog is allowlisted for explicit connect and disconnect", async () => {
  const calls = [];
  const schema = { describe() { return this; } };
  const activation = createMcpActivationTool((definition) => definition, {
    enum() { return schema; },
  }, {
    allowedNames: getOnDemandMcpAgents().map((entry) => entry.name),
    client: {
      async connect(request) { calls.push(["connect", request.path.name]); return {}; },
      async disconnect(request) { calls.push(["disconnect", request.path.name]); return {}; },
      async status() { return { data: { posthog: { status: "connected" } } }; },
    },
  });

  assert.match(await activation.execute({ action: "connect", name: "posthog" }), /Connected MCP/);
  assert.match(await activation.execute({ action: "disconnect", name: "posthog" }), /Disconnected MCP/);
  assert.deepEqual(calls, [["connect", "posthog"], ["disconnect", "posthog"]]);
});
