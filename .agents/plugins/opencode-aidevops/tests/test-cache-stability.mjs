// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
//
// Prompt-cache stability diagnostics (GH#32744).
//   node --test .agents/plugins/opencode-aidevops/tests/test-cache-stability.mjs

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { createCacheStabilityMonitor } from "../cache-stability.mjs";

const marker = { type: "ephemeral" };

function body({ tools = ["read", "edit"], prefix = "framework v1", turns = 1, billing = "cch=1;" } = {}) {
  const messages = [{ role: "user", content: [{ type: "text", text: prefix, cache_control: marker }, { type: "text", text: "task" }] }];
  for (let turn = 0; turn < turns; turn += 1) {
    messages.push({ role: "assistant", content: [{ type: "tool_use", id: `t${turn}`, name: "read", input: {} }] });
    messages.push({ role: "user", content: [{ type: "tool_result", tool_use_id: `t${turn}`, content: `out ${turn}` }] });
  }
  messages.at(-1).content.at(-1).cache_control = marker;
  return {
    tools: tools.map((name) => ({ name, description: name, input_schema: { type: "object" } })),
    system: [{ type: "text", text: `x-anthropic-billing-header: ${billing}` }, { type: "text", text: "identity" }],
    messages,
  };
}

function monitor() {
  const lines = [];
  return { lines, observe: createCacheStabilityMonitor({ log: (line) => lines.push(line), enabled: () => true }).observe };
}

describe("cache stability monitor", () => {
  test("ordinary growth, moving cache markers and the billing header are silent", () => {
    const { lines, observe } = monitor();
    observe(body({ turns: 1, billing: "cch=a;" }), { sessionID: "s" });
    observe(body({ turns: 2, billing: "cch=b;" }), { sessionID: "s" });
    observe(body({ turns: 3, billing: "cch=c;" }), { sessionID: "s" });
    assert.deepEqual(lines, []);
  });

  test("attributes tool, prefix, history and account changes", () => {
    const { lines, observe } = monitor();
    observe(body({ turns: 1 }), { sessionID: "s", account: "a@example.test" });
    observe(body({ turns: 2, tools: ["read", "edit", "mcp_x"] }), { sessionID: "s", account: "a@example.test" });
    assert.match(lines.at(-1), /family=agent segment=tools added=\[mcp_x\]/);

    observe(body({ turns: 3, tools: ["read", "edit", "mcp_x"], prefix: "framework v1\nWe're running v2" }), { sessionID: "s", account: "a@example.test" });
    assert.match(lines.at(-1), /segment=prefix .*line=2 was="" now="We're running v2"/);

    const mutated = body({ turns: 4, tools: ["read", "edit", "mcp_x"], prefix: "framework v1\nWe're running v2" });
    mutated.messages[2].content[0].content = "[pruned tool output]";
    observe(mutated, { sessionID: "s", account: "a@example.test" });
    assert.match(lines.at(-1), /segment=history index=2\/7 role=user block=0\/1 type=tool_result change=modified chars=5->20 now="\[pruned tool output\]"$/);

    observe(body({ turns: 5, tools: ["read", "edit", "mcp_x"], prefix: "framework v1\nWe're running v2" }), { sessionID: "s", account: "b@example.test" });
    assert.match(lines.at(-1), /segment=account from=\w+ to=\w+$/);
    assert.ok(!lines.join("\n").includes("example.test"), "account identities are hashed, never logged");
  });

  test("ignores requests without a session and fails closed to silence when disabled", () => {
    const lines = [];
    const off = createCacheStabilityMonitor({ log: (line) => lines.push(line), enabled: () => false });
    off.observe(body(), { sessionID: "s" });
    off.observe(body({ tools: ["other"] }), { sessionID: "s" });
    const on = createCacheStabilityMonitor({ log: (line) => lines.push(line), enabled: () => true });
    on.observe(body(), {});
    on.observe(body({ tools: ["other"] }), {});
    assert.deepEqual(lines, []);
  });

  test("separates auxiliary requests and attributes block removals", () => {
    const { lines, observe } = monitor();
    observe(body({ tools: [], turns: 1 }), { sessionID: "s" });
    observe(body({ turns: 1 }), { sessionID: "s" });
    observe(body({ tools: [], turns: 2 }), { sessionID: "s" });
    assert.deepEqual(lines, []);

    const first = body({ turns: 2 });
    first.messages[1].content.push({ type: "thinking", thinking: "private thought" });
    observe(first, { sessionID: "thinking" });
    const second = body({ turns: 3 });
    observe(second, { sessionID: "thinking" });
    assert.match(lines.at(-1), /family=agent segment=history index=1\/5 role=assistant block=1\/2 type=thinking change=removed chars=48->0/);
  });
});
