// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { homedir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { applyAgentMcpTools } from "../agent-mcp-tools.mjs";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import { getOnDemandMcpAgents, registerMcpServers } from "../mcp-registry.mjs";

const AGENTS_DIR = fileURLToPath(new URL("../../..", import.meta.url));
const profiles = [
  ["freecad", ["tools", "design", "freecad.md"]],
  ["davinci-resolve", ["tools", "video", "davinci-resolve.md"]],
  ["ableton-live", ["tools", "audio", "ableton-live.md"]],
];

test("creative MCPs register disabled behind the shared launcher", () => {
  const config = { mcp: {}, tools: {} };
  registerMcpServers(config);
  for (const [name] of profiles) {
    assert.deepEqual(config.mcp[name], {
      type: "local",
      command: [
        "python3",
        "-I",
        join(homedir(), ".aidevops", "agents", "scripts", "creative-mcp-launcher.py"),
        name,
      ],
      enabled: false,
    });
    assert.equal(config.tools[`${name}_*`], false);
  }
});

test("creative tools remain limited to focused app agents", () => {
  const config = { agent: { build: { tools: {} }, content: { tools: {} } } };
  registerOnDemandMcpAgents(config, AGENTS_DIR);
  applyAgentMcpTools(config);
  for (const [name] of profiles) {
    assert.equal(config.agent[name].tools[`${name}_*`], true);
    assert.equal(config.agent[name].tools.aidevops_mcp, true);
    assert.equal(config.agent.build.tools[`${name}_*`], undefined);
    assert.equal(config.agent.content.tools[`${name}_*`], undefined);
    assert.match(config.agent[name].prompt, /Require explicit operator approval/);
  }
});

test("creative MCP profiles preserve standard model pins and focused sources", () => {
  const entries = new Map(getOnDemandMcpAgents().map((entry) => [entry.name, entry]));
  for (const [name, source] of profiles) {
    assert.equal(entries.get(name).modelTier, "standard");
    assert.deepEqual(entries.get(name).agentSource, source);
  }
});
