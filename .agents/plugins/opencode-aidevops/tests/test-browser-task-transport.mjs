// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { assertBrowserTaskTransport, BROWSER_TASK_SCHEMA } from "../browser-task-transport.mjs";
import { createQualityHooks } from "../quality-hooks.mjs";

const ready = {
  capability: "browser-automation", decision: "route", evidence_scope: null,
  readiness: Object.fromEntries(["deployed", "enabled", "runtime_compatible", "tool_visible", "reachable"].map((key) => [key, "true"])),
};
const instructions = "Public target only; one attempt; fresh logged-out nonpersistent context; no secrets, recording, downloads or profile changes; stop on auth/challenge; close and clean up";
function request(transport, readiness = ready, extra = {}) {
  return { args: { subagent_type: "playwright", prompt: JSON.stringify({
    schema: BROWSER_TASK_SCHEMA, browser_transport: transport, readiness, prompt: instructions,
  }), ...extra } };
}

test("standalone-ready/MCP-unknown dispatch fails before native session or browser actions", async () => {
  const scriptsDir = fileURLToPath(new URL("../../../scripts/", import.meta.url));
  const hooks = createQualityHooks({ scriptsDir, logsDir: scriptsDir });
  const standalone = { ...ready, evidence_scope: { transport: "playwright", target_contacted: false, authenticated: false } };
  const unknownMcp = { ...ready, decision: "fallback", readiness: { ...ready.readiness, enabled: "unknown", tool_visible: "unknown", reachable: "unknown" } };
  let sessions = 0;
  let mcpConnects = 0;
  let browserActions = 0;
  async function nativeTask(output) {
    await hooks.toolExecuteBefore({ tool: "task" }, output);
    sessions += 1;
    mcpConnects += 1;
    browserActions += 1;
  }
  await assert.rejects(nativeTask(request("playwright", standalone)), /standalone Playwright.*no child created/);
  await assert.rejects(nativeTask(request("playwright", unknownMcp)), /standalone Playwright/);
  await assert.rejects(nativeTask(request("mcp", unknownMcp)), /MCP readiness/);
  assert.deepEqual([sessions, mcpConnects, browserActions], [0, 0, 0]);
});

test("approved fresh MCP envelope preserves bounded instructions and does not authorize another transport", () => {
  const output = request("mcp");
  const before = structuredClone(output);
  assert.doesNotThrow(() => assertBrowserTaskTransport({ tool: "task" }, output));
  assert.deepEqual(output, before);
  assert.throws(() => assertBrowserTaskTransport({ tool: "task" }, request("mcp", {
    ...ready, evidence_scope: { transport: "playwright" },
  })), /another transport/);
  for (const key of Object.keys(ready.readiness)) {
    assert.throws(() => assertBrowserTaskTransport({ tool: "task" }, request("mcp", {
      ...ready, readiness: { ...ready.readiness, [key]: "unknown" },
    })), /MCP readiness/);
  }
});

test("structured policy cannot change roles, resume children, or degrade to malformed JSON", () => {
  for (const extra of [{ task_id: "existing-child" }, { subagent_type: "general" }]) {
    assert.throws(() => assertBrowserTaskTransport({ tool: "task" }, request("mcp", ready, extra)), /fresh canonical/);
    assert.throws(() => assertBrowserTaskTransport({ tool: "task" }, request("playwright", ready, extra)), /standalone Playwright/);
  }
  for (const prompt of ['{"schema":', JSON.stringify({ browser_transport: "mcp" }), JSON.stringify({ schema: BROWSER_TASK_SCHEMA })]) {
    assert.throws(() => assertBrowserTaskTransport({ tool: "task" }, { args: { subagent_type: "playwright", prompt } }), /invalid/);
  }
  const output = request("playwright");
  output.args.prompt = `[effort:standard] ${output.args.prompt}`;
  assert.throws(() => assertBrowserTaskTransport({ tool: "task" }, output), /standalone Playwright/);
});

test("default browser behavior and unrelated research/tool requests are unchanged", () => {
  for (const output of [{ args: { subagent_type: "playwright", prompt: instructions } },
    { args: { subagent_type: "research-only", prompt: '{"task":"advisory"}' } }]) {
    assert.doesNotThrow(() => assertBrowserTaskTransport({ tool: "task" }, output));
  }
  assert.doesNotThrow(() => assertBrowserTaskTransport({ tool: "read" }, request("playwright")));
});

test("MCP readiness requirements match the current registry and configured role enables MCP", () => {
  const registry = JSON.parse(readFileSync(new URL("../../../configs/capability-registry.json", import.meta.url)));
  assert.deepEqual(registry.capabilities.find((item) => item.name === "browser-automation").required, Object.keys(ready.readiness));
  const role = readFileSync(new URL("../../../tools/browser/playwright.md", import.meta.url), "utf8");
  assert.match(role, /playwright_\*: true/);
  assert.match(role, /mcp:\n\s+- playwright/);
});
