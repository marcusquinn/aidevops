// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for the OpenCode token cost advisory threshold.
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-token-advisory-threshold.mjs

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createTtsrHooks } from "../ttsr.mjs";

function createHooks(options = {}) {
  const logs = [];
  const tempPrefix = `${Date.now()}-${process.pid}-${randomUUID()}-aidevops-token-advisory-test`;
  const hooks = createTtsrHooks({
    agentsDir: join(tmpdir(), `${tempPrefix}-agents`),
    scriptsDir: join(tmpdir(), `${tempPrefix}-scripts`),
    readIfExists: options.readIfExists || (() => ""),
    qualityLog: (level, message) => logs.push({ level, message }),
    run: () => "",
    intentField: "agent__intent",
    isHeadless: options.isHeadless || (() => false),
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
  test("prepends session greeting order to system prompt", async () => {
    const { hooks } = createHooks({
      readIfExists: (path) => path.endsWith("session-greeting.txt")
        ? "aidevops v3.14.23 running in OpenCode v1.14.33 | aidevops/main"
        : "",
    });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.match(output.system[0], /Session-start greeting order/);
    assert.match(output.system[0], /this exact aidevops greeting/);
    assert.match(output.system[0], /We're running aidevops v3\.14\.23 in OpenCode v1\.14\.33\./);
  });

  test("falls back to aidevops version when greeting cache is missing", async () => {
    const { hooks } = createHooks({
      readIfExists: (path) => path.endsWith("VERSION") ? "3.14.23\n" : "",
    });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.match(output.system[0], /We're running aidevops v3\.14\.23\./);
  });

  test("includes startup advisory only for warning and error cache lines", async () => {
    const { hooks } = createHooks({
      readIfExists: (path) => path.endsWith("session-greeting.txt")
        ? [
            "aidevops v3.14.23 running in OpenCode v1.14.33 | aidevops/main",
            "Security: all protections active",
            "[SECURITY ADVISORY] Rotate test credentials",
            "[WARN] Pulse stalled for 12 minutes",
          ].join("\n")
        : "",
    });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.match(output.system[0], /After the greeting, include this short startup advisory/);
    assert.match(output.system[0], /\[SECURITY ADVISORY\] Rotate test credentials/);
    assert.match(output.system[0], /\[WARN\] Pulse stalled for 12 minutes/);
    assert.doesNotMatch(output.system[0], /Security: all protections active/);
  });

  test("omits startup advisory section for clean cache", async () => {
    const { hooks } = createHooks({
      readIfExists: (path) => path.endsWith("session-greeting.txt")
        ? [
            "aidevops v3.14.23 running in OpenCode v1.14.33 | aidevops/main",
            "Security: all protections active",
          ].join("\n")
        : "",
    });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.doesNotMatch(output.system[0], /startup advisory/);
  });

  test("does not inject session greeting order in headless sessions", async () => {
    const { hooks } = createHooks({ isHeadless: () => true });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.equal(output.system[0], "base system prompt");
  });

  test("keeps Anthropic identity prefix separate from greeting order", async () => {
    const { hooks } = createHooks();
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "anthropic" } }, output);

    assert.match(output.system[0], /Session-start greeting order/);
    assert.equal(output.system[1], "You are Claude Code, Anthropic's official CLI for Claude.");
    assert.match(output.system[2], /^You are Claude Code, Anthropic's official CLI for Claude\.\n\nbase system prompt/);
  });

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

  test("does not inject advisory in headless sessions", async () => {
    const { hooks } = createHooks({ isHeadless: () => true });
    const output = outputForTokens(250_000);

    await hooks.messagesTransformHook({}, output);

    assert.equal(advisoryMessages(output).length, 0);
  });

  test("does not inject advisory for GPT-5.5 family models", async () => {
    const { hooks } = createHooks();
    const output = outputForTokens(250_000);

    await hooks.messagesTransformHook({ model: { modelID: "gpt-5.5-fast" } }, output);

    assert.equal(advisoryMessages(output).length, 0);
  });

  test("does not inject advisory for models newer than GPT-5.5", async () => {
    const { hooks } = createHooks();
    const output = outputForTokens(250_000);

    await hooks.messagesTransformHook({ model: { modelID: "gpt-6" } }, output);

    assert.equal(advisoryMessages(output).length, 0);
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
