// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";

import { createTtsrHooks } from "../ttsr.mjs";

function createHooks(files = {}, isHeadless = () => false) {
  const agentsDir = "/tmp/aidevops-greeting-test/agents";
  return createTtsrHooks({
    agentsDir,
    scriptsDir: join(agentsDir, "scripts"),
    readIfExists: (path) => files[path] || "",
    qualityLog: () => {},
    run: () => "",
    intentField: "agent__intent",
    isHeadless,
  });
}

async function greetingInstruction(hooks) {
  const output = { system: ["generated fallback guidance"] };
  await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);
  return output.system;
}

describe("authoritative session-start greeting", () => {
  test("plugin instruction is authoritative and uses cache runtime evidence", async () => {
    const cachePath = "/tmp/aidevops-greeting-test/cache/session-greeting.txt";
    const system = await greetingInstruction(createHooks({
      [cachePath]: "aidevops v3.32.12 running in OpenCode v1.17.18 | aidevops/main\nignored status",
    }));

    assert.match(system[0], /^## Session-start greeting order/);
    assert.match(system[0], /plugin-injected instruction is the authoritative greeting contract/);
    assert.match(system[0], /this exact aidevops greeting/);
    assert.match(system[0], /We're running aidevops v3\.32\.12 in OpenCode v1\.17\.18\./);
    assert.equal(system[1], "generated fallback guidance");
  });

  test("plugin instruction falls back to deployed VERSION when cache is missing", async () => {
    const versionPath = "/tmp/aidevops-greeting-test/agents/VERSION";
    const system = await greetingInstruction(createHooks({ [versionPath]: "3.32.12\n" }));

    assert.match(system[0], /We're running aidevops v3\.32\.12\./);
    assert.doesNotMatch(system[0], / in OpenCode v/);
  });

  test("plugin instruction preserves ordering and no-repeat safeguards", async () => {
    const system = await greetingInstruction(createHooks());

    assert.match(system[0], /before tool calls, status updates, analysis summaries, or task work/);
    assert.match(system[0], /If the user launched the session with an initial message, greet first/);
    assert.match(system[0], /Do not repeat the greeting after the first assistant turn/);
    assert.match(system[0], /do not duplicate the framework-status toast\/sidebar content/);
  });

  test("headless sessions receive no greeting instruction", async () => {
    const system = await greetingInstruction(createHooks({}, () => true));

    assert.equal(system[0], "generated fallback guidance");
    assert.equal(system.some((entry) => entry.includes("Session-start greeting order")), false);
  });
});
