// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { Plugin } from "@opencode/plugin";

import { getOpenCodeRuntimeProfile, profileForOpenCodeVersion } from "../runtime-profile.mjs";
import { loadV1ToolHelper, tool } from "../tools.mjs";
import v2Plugin, {
  applyV2PermissionEvaluation,
  createCompatibilityClient,
  createV2CompletionNormalizer,
  defineAidevopsV2Adapter,
  detectOpenCodeV2RuntimeVersion,
  OPENCODE_V2_CAPABILITIES,
  setupAidevopsV2,
  startEventLoop,
} from "../v2.mjs";
import { createV2McpRuntime, toV2McpConfig } from "../v2-mcp-adapter.mjs";
import { createV2ProviderAuthRuntime } from "../v2-provider-auth.mjs";
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

test("V2 runtime version comes from the V2 CLI package, never the V1 install", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-v2-version-"));
  try {
    const cliDir = join(root, "runtime", "node_modules", "@opencode", "cli");
    mkdirSync(join(cliDir, "bin"), { recursive: true });
    writeFileSync(join(cliDir, "package.json"), JSON.stringify({ name: "@opencode/cli", version: "2.0.3" }));
    const unrelated = join(root, "other", "bin");
    mkdirSync(unrelated, { recursive: true });
    writeFileSync(join(root, "other", "package.json"), JSON.stringify({ name: "node", version: "24.1.0" }));

    assert.equal(detectOpenCodeV2RuntimeVersion({ execPath: join(cliDir, "bin", "opencode.exe"), env: {}, home: root }), "2.0.3");
    assert.equal(
      detectOpenCodeV2RuntimeVersion({ execPath: join(unrelated, "node"), env: { AIDEVOPS_OPENCODE_V2_ROOT: root }, home: "/missing" }),
      "2.0.3",
    );
    assert.equal(detectOpenCodeV2RuntimeVersion({ execPath: join(unrelated, "node"), env: {}, home: "/missing" }), "");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("V2 directory loader resolves to the released V2 descriptor", async () => {
  const loader = await import("../v2-plugin/index.mjs");
  assert.equal(loader.default, v2Plugin);
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

test("V2 event processing continues after one handler failure", async () => {
  const events = [{ id: "first" }, { id: "second" }];
  const seen = [];
  let resolveProcessed;
  const processed = new Promise((resolve) => { resolveProcessed = resolve; });
  const stop = await startEventLoop({
    event: {
      async subscribe() {
        return {
          stream: {
            async *[Symbol.asyncIterator]() {
              yield events[0];
              yield events[1];
            },
          },
        };
      },
    },
  }, async ({ event }) => {
    seen.push(event.id);
    if (event.id === "first") throw new Error("synthetic handler failure");
    resolveProcessed();
  });

  await processed;
  await stop();
  assert.deepEqual(seen, ["first", "second"]);
});

// Captured through context-budget-helper.sh on OC2 2.0.3, 2026-10-03.
// Session/message IDs are redacted; public usage/model/timestamps are unchanged.
const capturedStepStart = {
  type: "session.step.started", created: 1790995311574,
  data: { sessionID: "ses_probe", assistantMessageID: "msg_probe", agent: "Build+",
    model: { id: "claude-haiku-4-5", providerID: "anthropic", variant: "default" } },
};
const capturedStepEnd = {
  type: "session.step.ended", created: 1790995311943,
  data: { sessionID: "ses_probe", assistantMessageID: "msg_probe", finish: "stop",
    cost: 0.02671675, tokens: { input: 3, output: 4, reasoning: 0, cache: { read: 0, write: 21355 } } },
};

test("captured OC2 step completion maps observed metadata and ignores incomplete/repeated events", () => {
  const normalize = createV2CompletionNormalizer();
  assert.equal(normalize(capturedStepEnd), null);
  assert.equal(normalize(capturedStepStart), null);
  for (const event of [undefined, {}, { type: "session.text.delta", data: capturedStepEnd.data },
    { ...capturedStepEnd, created: undefined }, { ...capturedStepEnd, data: {} }]) {
    assert.equal(normalize(event), null);
  }
  const completed = normalize(capturedStepEnd);
  assert.equal(completed.type, "message.updated");
  assert.deepEqual(completed.properties.info, {
    id: "msg_probe", sessionID: "ses_probe", role: "assistant", providerID: "anthropic",
    modelID: "claude-haiku-4-5", agent: "Build+", variant: "default", finish: "stop",
    tokens: capturedStepEnd.data.tokens, cost: capturedStepEnd.data.cost,
    time: { created: capturedStepStart.created, completed: capturedStepEnd.created },
  });
  assert.equal(normalize(capturedStepEnd), null);
});

test("production V2 event loop records exactly one SQLite row across replayed completion events", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-v2-usage-"));
  try {
    const result = spawnSync(process.execPath, ["--input-type=module", "-e", `
      import { createV2CompletionNormalizer, startEventLoop } from ${JSON.stringify(new URL("../v2.mjs", import.meta.url).href)};
      import { handleEvent, initObservability } from ${JSON.stringify(new URL("../observability.mjs", import.meta.url).href)};
      import { sqliteExecSync, shutdownSqlite } from ${JSON.stringify(new URL("../../../scripts/sqlite-process.mjs", import.meta.url).href)};
      initObservability({ runtimeVersion: "2.0.3", adapterId: "opencode-v2", aidevopsVersion: "3.37.91" });
      const normalize = createV2CompletionNormalizer();
      const events = ${JSON.stringify([capturedStepStart, capturedStepEnd, capturedStepEnd, capturedStepStart, capturedStepEnd])};
      let done;
      const processed = new Promise(resolve => { done = resolve; });
      const stop = await startEventLoop({ event: { subscribe: () => ({ async *[Symbol.asyncIterator]() {
        yield* events;
        done();
      } }) } }, input => {
        handleEvent(input);
        const completed = normalize(input.event);
        if (completed) handleEvent({ event: completed });
      });
      await processed;
      await stop();
      await new Promise(resolve => setTimeout(resolve, 100));
      console.log(sqliteExecSync("SELECT count(*) || '|' || model_id || '|' || session_id || '|' || tokens_input || '|' || tokens_output || '|' || tokens_cache_write || '|' || duration_ms || '|' || runtime_version || '|' || adapter_version FROM llm_requests;"));
      shutdownSqlite();
    `], { encoding: "utf8", timeout: 30000,
      env: { ...process.env, AIDEVOPS_OBS_DB_OVERRIDE: join(root, "usage.db") } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), "1|claude-haiku-4-5|ses_probe|3|4|21355|369|2.0.3|opencode-v2@3.37.91");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

for (const budgetEnabled of [false, true]) test(`V2 setup registers SDK lifecycle hooks and disposes every registration (240K budget ${budgetEnabled ? "enabled" : "disabled"})`, async () => {
  const previousSettingsFile = process.env.AIDEVOPS_SETTINGS_FILE;
  const settingsDir = mkdtempSync(join(tmpdir(), "aidevops-v2-adapter-"));
  process.env.AIDEVOPS_SETTINGS_FILE = join(settingsDir, "settings.json");
  try {
    // GH#32807: the budget is on by default; the disabled case is an explicit opt-out.
    if (!budgetEnabled) {
      writeFileSync(process.env.AIDEVOPS_SETTINGS_FILE, JSON.stringify({ runtime: { opencode: { v2_compaction_target: false } } }));
    }
  const registered = [];
  const disposed = [];
  const eventState = { returned: false };
  let failedRegistration = "";
  const register = (domain, name, callback) => {
    const key = `${domain}:${name}`;
    if (key === failedRegistration) return Promise.reject(new Error("synthetic registration failure"));
    registered.push({ domain, name, callback });
    return Promise.resolve({
      async dispose() {
        disposed.push(key);
      },
    });
  };
  const context = {
    app: { version: "2.0.3" },
    location: { directory: process.cwd(), project: { directory: process.cwd() } },
    event: {
      async subscribe() {
        return {
          stream: {
            [Symbol.asyncIterator]() {
              return {
                async next() {
                  return { done: true };
                },
                async return() {
                  eventState.returned = true;
                  return { done: true };
                },
              };
            },
          },
        };
      },
    },
    mcp: {
      transform: (callback) => register("mcp", "transform", callback),
      async list() {
        return [];
      },
      async reload() {},
    },
    agent: {
      transform: (callback) => register("agent", "transform", callback),
    },
    catalog: {
      transform: (callback) => register("catalog", "transform", callback),
    },
    permission: {
      hook: (name, callback) => register("permission", name, callback),
    },
    session: {
      hook: (name, callback) => register("session", name, callback),
      async get({ sessionID }) {
        return { id: sessionID, parentID: "" };
      },
      async rename() {},
    },
    shell: {
      hook: (name, callback) => register("shell", name, callback),
    },
    tool: {
      transform: (callback) => register("tool", "transform", callback),
      hook: (name, callback) => register("tool", name, callback),
    },
  };

  const cleanup = await setupAidevopsV2(context);
  assert.equal(typeof cleanup, "function");
  assert.deepEqual(registered.map(({ domain, name }) => `${domain}:${name}`), [
    "mcp:transform",
    "agent:transform",
    ...(budgetEnabled ? ["catalog:transform"] : []),
    "tool:transform",
    "tool:execute.before",
    "tool:execute.after",
    "shell:create.before",
    "session:context",
    "session:compaction",
    "session:http.request",
    "session:http.response",
    "session:retry",
    "permission:evaluate",
  ]);

  const contextHook = registered.find(({ domain, name }) => domain === "session" && name === "context").callback;
  const request = { sessionID: "v2-parity", model: { providerID: "anthropic", id: "test" }, system: [], messages: [] };
  await contextHook(request);
  const instructions = request.system.map(({ text }) => text).join("\n");
  assert.match(instructions, /if TodoWrite is unavailable, keep a short numbered task list/);
  assert.match(instructions, /search\(\{ namespace: "aidevops" \}\)/);

  await cleanup();
  assert.equal(eventState.returned, true);
  assert.deepEqual(disposed.sort(), registered.map(({ domain, name }) => `${domain}:${name}`).sort());

  // Newer V2 hosts may omit the catalogue transform; tool/context hooks still work.
  registered.length = 0;
  disposed.length = 0;
  delete context.catalog;
  const withoutCatalog = await setupAidevopsV2(context);
  assert.equal(registered.some(({ domain }) => domain === "catalog"), false);
  await withoutCatalog();

  registered.length = 0;
  disposed.length = 0;
  failedRegistration = "shell:create.before";
  await assert.rejects(() => setupAidevopsV2(context), /synthetic registration failure/);
  assert.deepEqual(disposed.sort(), registered.map(({ domain, name }) => `${domain}:${name}`).sort());

  registered.length = 0;
  disposed.length = 0;
  failedRegistration = "";
  context.event.subscribe = async () => { throw new Error("synthetic subscription failure"); };
  await assert.rejects(() => setupAidevopsV2(context), /synthetic subscription failure/);
  assert.deepEqual(disposed.sort(), registered.map(({ domain, name }) => `${domain}:${name}`).sort());
  } finally {
    if (previousSettingsFile === undefined) delete process.env.AIDEVOPS_SETTINGS_FILE;
    else process.env.AIDEVOPS_SETTINGS_FILE = previousSettingsFile;
    rmSync(settingsDir, { recursive: true, force: true });
  }
});

test("V2 compatibility client translates V1 session request shapes", async () => {
  const calls = [];
  const compatibility = createCompatibilityClient({
    session: {
      async get(input) {
        calls.push(["get", input]);
        return { id: input.sessionID, parentID: "" };
      },
      async rename(input) {
        calls.push(["rename", input]);
      },
    },
  }, {});

  assert.deepEqual(await compatibility.session.get({ path: { id: "session-1" } }), {
    data: { id: "session-1", parentID: "" },
  });
  await compatibility.session.update({ path: { id: "session-1" }, body: { title: "New title" } });
  assert.deepEqual(calls, [
    ["get", { sessionID: "session-1" }],
    ["rename", { sessionID: "session-1", title: "New title" }],
  ]);
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

test("V2 MCP toggles reuse one transform and apply the latest override", async () => {
  const transforms = [];
  let disposed = 0;
  let reloads = 0;
  const runtime = createV2McpRuntime({
    mcp: {
      async transform(callback) {
        transforms.push(callback);
        return { async dispose() { disposed += 1; } };
      },
      async reload() { reloads += 1; },
      async list() { return []; },
    },
  }, process.cwd());
  await runtime.initialize();

  const values = new Map();
  const editor = {
    get: (name) => values.get(name),
    set: (name, value) => values.set(name, value),
    update(name, callback) { callback(values.get(name)); },
  };
  transforms[0](editor);
  assert.equal(values.get("posthog").disabled, true);

  await runtime.client.connect({ path: { name: "posthog" } });
  transforms[0](editor);
  assert.equal(values.get("posthog").disabled, false);
  // On-demand servers keep V2 Code Mode (codemode defaults to true when unset).
  assert.notEqual(values.get("posthog").codemode, false);
  await runtime.client.disconnect({ path: { name: "posthog" } });
  transforms[0](editor);
  assert.equal(values.get("posthog").disabled, true);
  assert.equal(transforms.length, 1);
  assert.equal(reloads, 2);

  await runtime.dispose();
  assert.equal(disposed, 1);
});

test("V2 permission evaluation maps SDK action/resources to broker input", () => {
  let observed;
  const broker = {
    permissionAsk(input, output) {
      observed = input;
      output.status = "deny";
    },
  };
  const event = {
    sessionID: "session-1",
    action: "external_directory",
    resources: ["/outside"],
    effect: "ask",
  };

  applyV2PermissionEvaluation(broker, event);

  assert.equal(observed.type, "external_directory");
  assert.deepEqual(observed.patterns, ["/outside"]);
  assert.equal(event.effect, "deny");
  assert.equal("decision" in event, false);
});

test("V2 provider hooks rotate pooled accounts after a retryable response", async () => {
  const accounts = [
    { email: "first@example.com", access: "first-token" },
    { email: "second@example.com", access: "second-token" },
  ];
  const selections = [];
  const patches = [];
  const runtime = createV2ProviderAuthRuntime({
    getAccounts: (provider) => provider === "anthropic" ? accounts : [],
    selectRuntimePoolAccount: async (_provider, skipEmail) => {
      selections.push(skipEmail);
      return accounts.find((account) => account.email !== skipEmail);
    },
    patchAccount: (...args) => patches.push(args),
    markRejectedTokenFailure: () => {},
    ensureProviderActivation: () => {},
  });
  const requestEvent = {
    sessionID: "session-1",
    model: { providerID: "anthropic", modelID: "test-model" },
    request: new Request("https://example.test/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages: [] }),
    }),
  };

  await runtime.httpRequest(requestEvent);
  assert.equal(selections[0], "");
  assert.equal(patches[0][1], "first@example.com");

  await runtime.httpResponse({
    ...requestEvent,
    response: new Response("limited", { status: 429 }),
  });
  const retryEvent = {
    sessionID: "session-1",
    model: requestEvent.model,
    attempt: 1,
    decision: { retry: false },
  };
  runtime.retry(retryEvent);
  assert.deepEqual(retryEvent.decision, { retry: true, delay: 0 });

  requestEvent.request = new Request("https://example.test/v1/messages", {
    method: "POST",
    body: JSON.stringify({ messages: [] }),
  });
  await runtime.httpRequest(requestEvent);
  assert.equal(selections[1], "first@example.com");
});

test("V2 provider responses retain request-specific account affinity", async () => {
  const accounts = [
    { email: "first@example.com", access: "first-token" },
    { email: "second@example.com", access: "second-token" },
  ];
  const patches = [];
  let selected = 0;
  const runtime = createV2ProviderAuthRuntime({
    getAccounts: (provider) => provider === "anthropic" ? accounts : [],
    selectRuntimePoolAccount: async () => accounts[selected++],
    patchAccount: (...args) => patches.push(args),
    markRejectedTokenFailure: () => {},
    ensureProviderActivation: () => {},
  });
  const requestEvent = () => ({
    sessionID: "session-1",
    model: { providerID: "anthropic", modelID: "test-model" },
    request: new Request("https://example.test/v1/messages", {
      method: "POST",
      body: JSON.stringify({ messages: [] }),
    }),
  });
  const first = requestEvent();
  const second = requestEvent();
  await runtime.httpRequest(first);
  await runtime.httpRequest(second);
  await runtime.httpResponse({ ...first, response: new Response("limited", { status: 429 }) });

  const rateLimitPatch = patches.find(([, email, patch]) => email === "first@example.com" && patch.status === "rate-limited");
  assert.ok(rateLimitPatch);
  assert.equal(patches.some(([, email, patch]) => email === "second@example.com" && patch.status === "rate-limited"), false);
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

test("project custom tools use the host-resolved V1 schema package", () => {
  for (const relativePath of ["session-rename.ts", "ai-research.ts"]) {
    const source = readFileSync(
      new URL(`../../../../.opencode/tool/${relativePath}`, import.meta.url),
      "utf8",
    );
    assert.match(source, /from "@opencode-ai\/plugin"/);
    assert.doesNotMatch(source, /tool-schema\.mjs/);
  }
});
