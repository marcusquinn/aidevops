// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// GH#34125 Phase 1 (t18630): operator-bound local-only egress gate.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  LOCAL_PROVIDERS_FILE,
  assertLocalOnlyEgress,
  isLoopbackDestination,
  loadLocalOnlyPolicy,
  parseLocalProviders,
} from "../local-only-policy.mjs";
import { selectConnectedRoutingCandidate } from "../model-routing.mjs";

const PLUGIN_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const REPO_ROOT = resolve(PLUGIN_DIR, "../../..");
const SENTINEL = "SENTINEL-GH34125-must-not-leave-device";

test("binding: unset and provider-* opt-outs are unbound; local tokens and unknown values bind", () => {
  assert.equal(loadLocalOnlyPolicy({}).bound, false);
  assert.equal(loadLocalOnlyPolicy({ AIDEVOPS_RUNTIME_POLICY: "provider-ai" }).bound, false);
  for (const value of ["local-only", "LOCAL-LLM-ONLY", " local-ai "]) {
    const policy = loadLocalOnlyPolicy({ AIDEVOPS_RUNTIME_POLICY: value });
    assert.equal(policy.bound, true, value);
    assert.equal(policy.reason, "declared");
  }
  const unknown = loadLocalOnlyPolicy({ AIDEVOPS_RUNTIME_POLICY: "lcoal-only" });
  assert.equal(unknown.bound, true);
  assert.equal(unknown.reason, "unrecognised-policy-fails-closed");
});

test("binding is frozen and the shared provider list matches the headless helper", () => {
  const policy = loadLocalOnlyPolicy({ AIDEVOPS_RUNTIME_POLICY: "local-only" });
  assert.ok(Object.isFrozen(policy) && Object.isFrozen(policy.localProviders));
  assert.throws(() => { policy.bound = false; }, TypeError);
  assert.equal(LOCAL_PROVIDERS_FILE, join(REPO_ROOT, ".agents/configs/local-ai-providers.conf"));
  assert.deepEqual([...policy.localProviders], ["local", "ollama", "llama", "llama.cpp", "llamacpp"]);
  assert.deepEqual(parseLocalProviders("# c\n ollama # x\n\nlocal\n"), ["ollama", "local"]);
});

test("missing provider list fails closed: a bound session treats nothing as local", () => {
  const policy = loadLocalOnlyPolicy(
    { AIDEVOPS_RUNTIME_POLICY: "local-only" },
    { providersFile: join(tmpdir(), "aidevops-missing-local-providers.conf") },
  );
  assert.throws(
    () => assertLocalOnlyEgress(policy, { model: { providerID: "ollama" } }, "chat"),
    { code: "VAULT_POLICY_DENIED" },
  );
});

const LOCAL_URL = "http://127.0.0.1:11434/v1";

test("egress gate: V1 and V2 input shapes; unknown provider is non-local; unbound is a no-op", () => {
  const bound = loadLocalOnlyPolicy({ AIDEVOPS_RUNTIME_POLICY: "local-only" });
  assert.doesNotThrow(() => assertLocalOnlyEgress(bound, { model: { providerID: "ollama", api: { url: LOCAL_URL } } }, "chat"));
  assert.doesNotThrow(() => assertLocalOnlyEgress(
    bound, { provider: { info: { id: "local" }, options: { baseURL: "http://localhost:8080" } } }, "chat"));
  assert.doesNotThrow(() => assertLocalOnlyEgress(
    bound, { model: { providerID: "ollama" }, request: new Request("http://[::1]:11434/api/chat") }, "http"));
  assert.doesNotThrow(() => assertLocalOnlyEgress(bound, { model: { providerID: "ollama" } }, "context"));
  assert.throws(() => assertLocalOnlyEgress(bound, { model: { providerID: "openai" } }, "http"), /VAULT_POLICY_DENIED/);
  assert.throws(() => assertLocalOnlyEgress(bound, {}, "context"), /provider "unknown"/);
  const unbound = loadLocalOnlyPolicy({});
  assert.doesNotThrow(() => assertLocalOnlyEgress(unbound, { model: { providerID: "openai" } }, "chat"));
});

test("egress gate: a remote endpoint under a local provider name is refused (security review GH#34125)", () => {
  const bound = loadLocalOnlyPolicy({ AIDEVOPS_RUNTIME_POLICY: "local-only" });
  const remoteUnderLocalName = [
    // V1: options.baseURL overrides model.api.url, as in OpenCode resolveSDK.
    [{ model: { providerID: "ollama", api: { url: LOCAL_URL } }, provider: { options: { baseURL: "https://api.example.com/v1" } } }, "chat"],
    [{ model: { providerID: "ollama", api: { url: "https://api.example.com/v1" } } }, "chat"],
    [{ model: { providerID: "ollama" } }, "chat"],
    [{ model: { providerID: "ollama" }, request: new Request("https://api.example.com/v1/chat") }, "http"],
    [{ model: { providerID: "ollama", api: { url: "http://192.168.1.20:11434/v1" } } }, "chat"],
    [{ model: { providerID: "ollama", api: { url: "http://0.0.0.0:11434/v1" } } }, "chat"],
    [{ model: { providerID: "ollama", api: { url: "http://${OLLAMA_HOST}/v1" } } }, "chat"],
    [{ model: { providerID: "ollama", api: { url: "http://localhost.example.com/v1" } } }, "chat"],
  ];
  for (const [input, surface] of remoteUnderLocalName) {
    assert.throws(() => assertLocalOnlyEgress(bound, input, surface), /non-loopback or unknown endpoint/, JSON.stringify(input));
  }
  assert.equal(isLoopbackDestination("http://127.10.0.1:1234"), true);
  assert.equal(isLoopbackDestination("file:///etc/passwd"), false);
});

test("bound routing never selects a non-local candidate; no local candidate yields empty", () => {
  const routing = { tiers: { standard: { models: ["openai/primary", "ollama/qwen", "anthropic/fallback"] } } };
  const providerState = {
    connected: ["openai", "ollama", "anthropic"],
    all: [
      { id: "openai", models: { primary: { id: "primary" } } },
      { id: "ollama", models: { qwen: { id: "qwen" } } },
      { id: "anthropic", models: { fallback: { id: "fallback" } } },
    ],
  };
  const bound = loadLocalOnlyPolicy({ AIDEVOPS_RUNTIME_POLICY: "local-only" });
  assert.equal(selectConnectedRoutingCandidate(routing, "standard", providerState, bound), "ollama/qwen");
  const noLocal = { connected: ["openai", "anthropic"], all: providerState.all };
  assert.equal(selectConnectedRoutingCandidate(routing, "standard", noLocal, bound), "");
  assert.equal(
    selectConnectedRoutingCandidate(routing, "standard", providerState, loadLocalOnlyPolicy({})),
    "openai/primary",
  );
});

// Real plugin factory in an isolated child, driven in OpenCode request order:
// chat.params runs before the provider stream (session/llm/request.ts), and a
// thrown hook aborts the request (plugin/index.ts Effect.promise).
function runPluginRequest(providerID, runtimePolicy, apiUrl = LOCAL_URL) {
  const home = mkdtempSync(join(tmpdir(), "aidevops-local-only-home-"));
  const script = [
    "const [pluginUrl, directory, providerID, sentinel, apiUrl] = process.argv.slice(1);",
    "const sent = [];",
    "const pluginModule = await import(pluginUrl);",
    "const hooks = await pluginModule.AidevopsPlugin({ directory, client: {} });",
    "process.env.AIDEVOPS_RUNTIME_POLICY = '';",
    "const input = { sessionID: 'ses_t', agent: 'build', model: { providerID, id: 'm', modelID: 'm', api: { url: apiUrl } },",
    "  provider: { info: { id: providerID }, options: {} }, message: { id: 'msg_t', sessionID: 'ses_t' } };",
    "let denial = '';",
    "try { await hooks['chat.params'](input, { options: {} }); sent.push(sentinel); }",
    "catch (error) { denial = String(error?.message || error); }",
    "process.stdout.write(JSON.stringify({ denial, sent }));",
    "process.exit(0);",
  ].join("\n");
  const env = { PATH: process.env.PATH || "/usr/bin:/bin", HOME: home, AIDEVOPS_HEADLESS: "1" };
  if (runtimePolicy) env.AIDEVOPS_RUNTIME_POLICY = runtimePolicy;
  try {
    const result = spawnSync(
      process.execPath,
      ["--input-type=module", "-e", script, pathToFileURL(join(PLUGIN_DIR, "index.mjs")).href, REPO_ROOT, providerID, SENTINEL, apiUrl],
      { cwd: REPO_ROOT, encoding: "utf8", env, timeout: 60000 },
    );
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

test("sentinel: bound session blocks a remote provider before send, even after env is cleared", () => {
  const evidence = runPluginRequest("anthropic", "local-only");
  assert.match(evidence.denial, /^VAULT_POLICY_DENIED: /);
  assert.ok(!evidence.denial.includes(SENTINEL), "denial must be content-free");
  assert.deepEqual(evidence.sent, []);
});

test("sentinel: bound session allows a local provider; unbound session is unchanged", () => {
  assert.deepEqual(runPluginRequest("ollama", "local-only"), { denial: "", sent: [SENTINEL] });
  assert.deepEqual(runPluginRequest("anthropic", "", "https://api.anthropic.com/v1"), { denial: "", sent: [SENTINEL] });
});

test("sentinel: bound session blocks a remote endpoint configured under a local provider name", () => {
  const evidence = runPluginRequest("ollama", "local-only", "https://api.example.com/v1");
  assert.match(evidence.denial, /non-loopback or unknown endpoint/);
  assert.ok(!evidence.denial.includes("api.example.com"), "denial must not echo the endpoint");
  assert.deepEqual(evidence.sent, []);
});
