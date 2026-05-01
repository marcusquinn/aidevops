// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for the OpenCode token cost advisory threshold.
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-token-advisory-threshold.mjs

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { createTtsrHooks } from "../ttsr.mjs";

function createHooks() {
  const logs = [];
  const hooks = createTtsrHooks({
    agentsDir: "/tmp/aidevops-token-advisory-test-agents",
    scriptsDir: "/tmp/aidevops-token-advisory-test-scripts",
    readIfExists: () => "",
    qualityLog: (level, message) => logs.push({ level, message }),
    run: () => "",
    intentField: "agent__intent",
  });
  return { hooks, logs };
}

function outputForTokens(total, sessionID = "token-advisory-test-session") {
  return {
    messages: [{
      info: {
        id: `assistant-${total}`,
        role: "assistant",
        sessionID,
        tokens: { input: total, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
      },
      parts: [{ type: "text", text: "assistant response" }],
    }],
  };
}

function advisoryMessages(output) {
  return output.messages.filter((msg) => msg.info?.id?.startsWith("token-advisory-"));
}

describe("token cost advisory threshold", () => {
  test("does not inject advisory below 250k tokens", async () => {
    const { hooks } = createHooks();
    const output = outputForTokens(249_999);

    await hooks.messagesTransformHook({}, output);

    assert.equal(advisoryMessages(output).length, 0);
  });

  test("injects first advisory at 250k tokens", async () => {
    const { hooks, logs } = createHooks();
    const output = outputForTokens(250_000);

    await hooks.messagesTransformHook({}, output);

    const advisories = advisoryMessages(output);
    assert.equal(advisories.length, 1);
    assert.match(advisories[0].parts[0].text, /approximately 250k tokens/);
    assert.deepEqual(logs, [{ level: "INFO", message: "Token advisory: session token-advisory-test-session at ~250k tokens" }]);
  });

  test("does not repeat at the same threshold for a session", async () => {
    const { hooks } = createHooks();
    const first = outputForTokens(250_000);
    const second = outputForTokens(275_000);

    await hooks.messagesTransformHook({}, first);
    await hooks.messagesTransformHook({}, second);

    assert.equal(advisoryMessages(first).length, 1);
    assert.equal(advisoryMessages(second).length, 0);
  });

  test("fires again at the next 50k interval", async () => {
    const { hooks } = createHooks();
    const first = outputForTokens(250_000);
    const second = outputForTokens(300_000);

    await hooks.messagesTransformHook({}, first);
    await hooks.messagesTransformHook({}, second);

    const advisories = advisoryMessages(second);
    assert.equal(advisories.length, 1);
    assert.match(advisories[0].parts[0].text, /approximately 300k tokens/);
  });
});
