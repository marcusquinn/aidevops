// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Plugin } from "@opencode/plugin";

import { getOpenCodeRuntimeProfile, profileForOpenCodeVersion } from "../runtime-profile.mjs";
import { loadV1ToolHelper, tool } from "../tools.mjs";
import v2Plugin, {
  defineAidevopsV2Adapter,
  OPENCODE_V2_CAPABILITIES,
} from "../v2.mjs";
import { toV2McpConfig } from "../v2-mcp-adapter.mjs";
import { addV1ToolsToV2Editor, toV2ToolResult } from "../v2-tool-adapter.mjs";

test("package exposes released V1 and V2 plugin entrypoints", () => {
  const packageDocument = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  assert.equal(packageDocument.exports["./v1"], "./index.mjs");
  assert.equal(packageDocument.exports["./v2"], "./v2.mjs");
  assert.equal(packageDocument.dependencies["@opencode/plugin"], "2.0.3");
  assert.equal(v2Plugin.id, "aidevops");
  assert.equal(typeof v2Plugin.setup, "function");
  assert.equal(Plugin.define(v2Plugin), v2Plugin);
});

test("V2 descriptor seam uses the released Plugin.define contract", async () => {
  const context = { app: { version: "2.0.3" } };
  let observed;
  const cleanup = () => {};
  const plugin = defineAidevopsV2Adapter(async (input) => {
    observed = input;
    return cleanup;
  });

  assert.equal(await plugin.setup(context), cleanup);
  assert.equal(observed, context);
  assert.throws(() => defineAidevopsV2Adapter(), /setup must be a function/);
  assert.equal(OPENCODE_V2_CAPABILITIES.tools, true);
  assert.equal(OPENCODE_V2_CAPABILITIES.textCompletionHook, false);
});

test("versioned runtime profiles keep SDK-specific names outside shared logic", () => {
  assert.equal(getOpenCodeRuntimeProfile("v1").package, "opencode-ai");
  assert.equal(getOpenCodeRuntimeProfile("v1").configPluginKey, "plugin");
  assert.equal(getOpenCodeRuntimeProfile("v2").package, "@opencode/cli");
  assert.equal(getOpenCodeRuntimeProfile("v2").configPluginKey, "plugins");
  assert.equal(profileForOpenCodeVersion("1.18.31").id, "v1");
  assert.equal(profileForOpenCodeVersion("OpenCode 2.0.3").id, "v2");
});

test("V1 tool definitions adapt to structured V2 registrations", async () => {
  const added = [];
  addV1ToolsToV2Editor({ add: (definition) => added.push(definition) }, {
    sample: tool({
      description: "sample tool",
      args: { value: tool.schema.string() },
      async execute(args, context) {
        return `${args.value}:${context.directory}`;
      },
    }),
  }, tool.schema, { directory: "/repo", worktree: "/repo" });

  assert.equal(added.length, 1);
  assert.equal(added[0].name, "sample");
  assert.deepEqual(await added[0].execute({ value: "ok" }, { sessionID: "s1" }), {
    content: "ok:/repo",
  });
  assert.deepEqual(toV2ToolResult({ output: { ok: true }, content: "done" }), {
    output: { ok: true },
    content: "done",
  });
});

test("V1 MCP enablement maps to V2 disabled semantics", () => {
  assert.deepEqual(toV2McpConfig({
    type: "local",
    command: ["node", "server.mjs"],
    env: { MODE: "test" },
    enabled: false,
  }), {
    type: "local",
    command: ["node", "server.mjs"],
    environment: { MODE: "test" },
    disabled: true,
  });
});

test("V1 tool schemas still resolve across stable package layouts", async () => {
  const helper = (definition) => definition;
  helper.schema = {};
  const attempts = [];
  const selected = await loadV1ToolHelper({
    importer: async (specifier) => {
      attempts.push(specifier);
      if (specifier.endsWith("/v1")) return { tool: helper };
      throw new Error("root import must not be reached");
    },
  });
  assert.equal(selected, helper);
  assert.deepEqual(attempts, ["@opencode-ai/plugin/v1"]);

  const fallback = await loadV1ToolHelper({
    importer: async (specifier) => {
      if (specifier.endsWith("/v1")) throw new Error("legacy package has no v1 export");
      return { tool: helper };
    },
  });
  assert.equal(fallback, helper);
});
