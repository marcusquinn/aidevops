// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
//
// TTSR system.transform contract for OpenCode 1 and 2 (GH#32444).
//   node --test .agents/plugins/opencode-aidevops/tests/test-ttsr-system-transform.mjs

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { CLAUDE_CODE_IDENTITY, createTtsrHooks, isPluginGreetingEnabled } from "../ttsr.mjs";

function hooks(overrides = {}) {
  return createTtsrHooks({
    agentsDir: "/nonexistent/agents",
    scriptsDir: "/nonexistent/scripts",
    readIfExists: () => null,
    qualityLog: () => {},
    run: () => "",
    intentField: "agent__intent",
    shouldInjectGreeting: async () => true,
    readGreetingCache: () => null,
    ...overrides,
  });
}

function wrapper(name) {
  return `<skill>\n<name>aidevops-${name}</name>\n<description>Run the aidevops ${name} workflow when explicitly requested.</description>\n<location>/skills/aidevops-${name}/SKILL.md</location>\n</skill>`;
}

describe("TTSR system transform", () => {
  test("mutates the runtime-owned system array in place (OpenCode 1 ignores reassignment)", async () => {
    const { systemTransformHook } = hooks({ greetingEnabled: () => false });
    const catalogue = `Agent prompt.\n<available_skills>\n${["seo", "review", "release"].map(wrapper).join("\n")}\n</available_skills>`;
    const system = [catalogue];
    const output = { system };

    await systemTransformHook({ sessionID: "ses_1", model: { providerID: "openai" } }, output);

    assert.equal(output.system, system, "the original array reference must carry the result");
    assert.ok(!system[0].includes("<location>"), "catalogue compaction must reach the runtime array");
    assert.match(system[0], /aidevops-seo/);
    assert.ok(system.some((text) => text.startsWith("## Intent Tracing (observability)")));
    assert.ok(system.some((text) => text.startsWith("## aidevops Quality Rules (enforced)")));
  });

  test("keeps the exact Anthropic identity shape for both runtimes and none for other providers", async () => {
    const { systemTransformHook } = hooks({ greetingEnabled: () => false });
    const system = ["Agent prompt."];

    await systemTransformHook({ sessionID: "ses_1", model: { providerID: "anthropic" } }, { system });

    assert.equal(system[0], CLAUDE_CODE_IDENTITY, "identity must be its own first block");
    assert.equal(system[1], `${CLAUDE_CODE_IDENTITY}\n\nAgent prompt.`);

    const openai = ["Agent prompt."];
    await systemTransformHook({ sessionID: "ses_1", model: { providerID: "openai" } }, { system: openai });
    assert.equal(openai[0], "Agent prompt.");
    assert.ok(!openai.some((text) => text.includes(CLAUDE_CODE_IDENTITY)));
  });

  test("keeps the plugin greeting off by default and appends it after durable guidance when enabled", async () => {
    assert.equal(isPluginGreetingEnabled({}), false);
    assert.equal(isPluginGreetingEnabled({ AIDEVOPS_PLUGIN_SESSION_GREETING: "1" }), true);
    // OpenCode 2 passes a true runtime default; the env override still wins.
    assert.equal(isPluginGreetingEnabled({}, true), true);
    assert.equal(isPluginGreetingEnabled({ AIDEVOPS_PLUGIN_SESSION_GREETING: "0" }, true), false);

    const off = ["Agent prompt."];
    await hooks({ greetingEnabled: () => false }).systemTransformHook(
      { sessionID: "ses_1", model: { providerID: "anthropic" } },
      { system: off },
    );
    assert.ok(!off.some((text) => text.includes("Session-start greeting order")));

    for (const providerID of ["anthropic", "openai"]) {
      const on = ["Agent prompt."];
      await hooks({ greetingEnabled: () => true }).systemTransformHook(
        { sessionID: "ses_2", model: { providerID } },
        { system: on },
      );
      assert.ok(on.at(-2).startsWith("## aidevops Quality Rules") || on.at(-2).startsWith("## Intent Tracing"));
      assert.match(on.at(-1), /^## Session-start greeting order/);
    }
  });
});
