// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// GH#34125 Phase 1 (t18630): operator-bound local-only egress gate.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  LOCAL_PROVIDERS_FILE,
  LOCAL_ONLY_CURL,
  assertLocalOnlyEgress,
  assertLocalOnlyToolCall,
  captureLocalOnlyMcpConfig,
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
function runPluginRequest(providerID, runtimePolicy, apiUrl = LOCAL_URL, agent = "build") {
  const home = mkdtempSync(join(tmpdir(), "aidevops-local-only-home-"));
  const script = [
    "const [pluginUrl, directory, providerID, sentinel, apiUrl, agent] = process.argv.slice(1);",
    "const sent = [];",
    "const pluginModule = await import(pluginUrl);",
    "const hooks = await pluginModule.AidevopsPlugin({ directory, client: {} });",
    "process.env.AIDEVOPS_RUNTIME_POLICY = '';",
    "const input = { sessionID: 'ses_t', agent, model: { providerID, id: 'm', modelID: 'm', api: { url: apiUrl } },",
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
      ["--input-type=module", "-e", script, pathToFileURL(join(PLUGIN_DIR, "index.mjs")).href, REPO_ROOT, providerID, SENTINEL, apiUrl, agent],
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

test("delegated specialist with an explicit remote model is denied at the real chat.params hook", () => {
  const evidence = runPluginRequest("anthropic", "local-only", "https://api.example.com/v1", "specialist-advisor");
  assert.match(evidence.denial, /VAULT_POLICY_DENIED/);
  assert.deepEqual(evidence.sent, []);
});

test("tool policy rejects opaque execution, wrappers, unknown MCP and unsafe curl options", () => {
  const policy = loadLocalOnlyPolicy({ AIDEVOPS_RUNTIME_POLICY: "local-only" });
  const config = { local_server: { type: "local" }, loop: { type: "remote", url: LOCAL_URL },
    remote: { type: "remote", url: "https://api.example.com" } };
  captureLocalOnlyMcpConfig(config);
  config.loop.url = "https://api.example.com";
  for (const tool of ["local_server_read", "mcp__local_server__read", "loop_read", "read", "task"]) {
    assert.doesNotThrow(() => assertLocalOnlyToolCall(tool, {}, policy));
  }
  const attacks = [
    ["remote_read", {}], ["unknown_read", {}], ["mcp__unknown__read", {}],
    ["webfetch", { url: SENTINEL }], ["websearch", { query: SENTINEL }],
    ["gpt_image_generate", { prompt: SENTINEL }], ["aidevops_on_demand", { tool: "gpt_image_generate" }],
    ...["curl https://api.example.com/" + SENTINEL, "wget " + SENTINEL, "ssh host", "git push", "gh api", "nc host 123",
      "python3 -c 'import socket'", "env -u AIDEVOPS_RUNTIME_POLICY curl https://api.example.com", "./custom-binary",
      "/usr/bin/curl --disable --noproxy '*' --proxy '' --max-time 30 --url 'http://127.0.0.1:1234' -L",
      "/usr/bin/curl --disable --noproxy '*' --proxy '' --max-time 30 --url 'http://127.0.0.1:1234/$(id)'",
    ].map((command) => ["bash", { command }]),
    ["aidevops_bounded_operation", { action: "start", command: ["python3", "-c", SENTINEL] }],
    ["aidevops_mcp", { action: "connect", name: "remote" }],
  ];
  for (const [tool, args] of attacks) {
    assert.throws(() => assertLocalOnlyToolCall(tool, args, policy), (error) =>
      error.code === "VAULT_POLICY_DENIED" && !error.message.includes(SENTINEL));
    assert.doesNotThrow(() => assertLocalOnlyToolCall(tool, args, loadLocalOnlyPolicy({})));
  }
  const argv = [LOCAL_ONLY_CURL, "--disable", "--noproxy", "*", "--proxy", "", "--max-time", "30", "--url", LOCAL_URL];
  assert.doesNotThrow(() => assertLocalOnlyToolCall("aidevops_bounded_operation", { action: "start", command: argv }, policy));
  assert.throws(() => assertLocalOnlyToolCall("aidevops_bounded_operation", {
    action: "start", command: argv, restoration_command: ["curl", "https://api.example.com"],
  }, policy), /VAULT_POLICY_DENIED/);
});

function childResult(command, args, env) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command, args, { cwd: REPO_ROOT, env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (data) => { stdout += data; });
    child.stderr.on("data", (data) => { stderr += data; });
    child.on("error", reject);
    child.on("close", (status) => resolveResult({ status, stdout, stderr }));
  });
}

test("real pre-tool hooks: fake external endpoint receives nothing; literal loopback curl and MCP work", async () => {
  const received = [];
  const server = createServer((request, response) => {
    received.push(request.url);
    response.end("local-ok");
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  const home = mkdtempSync(join(tmpdir(), "aidevops-tools-local-only-"));
  try {
    const port = server.address().port;
    const script = `
      import assert from 'node:assert/strict';
      import { execFileSync } from 'node:child_process';
      const [pluginDir, home, port, sentinel] = process.argv.slice(1);
      const policy = await import(pluginDir + '/local-only-policy.mjs');
      policy.initLocalOnlyPolicy();
      process.env.AIDEVOPS_RUNTIME_POLICY = '';
      policy.captureLocalOnlyMcpConfig({ remote: {type:'remote',url:'http://0.0.0.0:'+port}, local: {type:'local'} },home);
      const {createQualityHooks} = await import(pluginDir + '/quality-hooks.mjs');
      const hooks = createQualityHooks({scriptsDir: pluginDir+'/../../scripts', logsDir: home, repositoryDir: home});
      const external = 'http://0.0.0.0:'+port+'/'+sentinel;
      for (const [tool,args] of [['remote_send',{content:sentinel}],['webfetch',{url:external}],
        ['gpt_image_generate',{prompt:sentinel}],['bash',{command:'curl '+external}]]) {
        await assert.rejects(hooks.toolExecuteBefore({tool},{args}), {code:'VAULT_POLICY_DENIED'});
      }
      const schema = {describe(){return this},optional(){return this}};
      const z = {string:()=>schema,enum:()=>schema,array:()=>schema};
      const {createGptImageTool} = await import(pluginDir + '/gpt-image-tool.mjs');
      let sent = 0;
      const image = createGptImageTool(x=>x,z,{fetchImpl:async()=>{sent++;}});
      await assert.rejects(image.execute({prompt:sentinel,out:'x.png'}), {code:'VAULT_POLICY_DENIED'});
      const {createMcpActivationTool} = await import(pluginDir + '/mcp-activation-tool.mjs');
      const mcp = createMcpActivationTool(x=>x,z,{allowedNames:['remote','local'],directory:home,
        client:{connect:async()=>{sent++;}}});
      await assert.rejects(mcp.execute({action:'connect',name:'remote'},{agent:'remote'}), {code:'VAULT_POLICY_DENIED'});
      assert.equal(sent,0);
      assert.match(await mcp.execute({action:'connect',name:'local'},{agent:'local'}), /Connected/);
      await hooks.toolExecuteBefore({tool:'local_send'},{args:{content:sentinel}});
      const url = 'http://127.0.0.1:'+port+'/local';
      const command = policy.LOCAL_ONLY_CURL+" --disable --noproxy '*' --proxy '' --max-time 30 --url '"+url+"'";
      const shell = {args:{command:'curl '+url,workdir:home}};
      await hooks.toolExecuteBefore({tool:'bash'},shell);
      assert.equal(shell.args.command,command);
      const bounded = {args:{action:'start',command:['curl',url],cwd:home}};
      await hooks.toolExecuteBefore({tool:'aidevops_bounded_operation'},bounded);
      assert.equal(bounded.args.command[0],policy.LOCAL_ONLY_CURL);
      assert.equal(bounded.args.command[1],'--disable');
      const result = execFileSync(policy.LOCAL_ONLY_CURL,['--disable','--noproxy','*','--proxy','','--max-time','30','--url',url],{encoding:'utf8'});
      assert.equal(result,'local-ok');
      const {createShellEnvHook} = await import(pluginDir + '/shell-env.mjs');
      process.env.OTEL_EXPORTER_OTLP_ENDPOINT = external;
      const output = {env:{}};
      await createShellEnvHook({})({},output);
      assert.equal(output.env.OTEL_SDK_DISABLED,'true');
      assert.equal(output.env.OTEL_EXPORTER_OTLP_ENDPOINT,'');
      assert.equal(output.env.AIDEVOPS_RUNTIME_POLICY,'local-only');
      const {enrichActiveSpan} = await import(pluginDir + '/otel-enrichment.mjs');
      assert.equal(await enrichActiveSpan({'aidevops.intent':sentinel}),false);
      process.stdout.write('verified');
    `;
    const result = await childResult(process.execPath, ["--input-type=module", "-e", script, PLUGIN_DIR, home, String(port), SENTINEL],
      { PATH: process.env.PATH, HOME: home, AIDEVOPS_RUNTIME_POLICY: "local-only" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "verified");
    assert.deepEqual(received, ["/local"]);
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose));
    rmSync(home, { recursive: true, force: true });
  }
});

test("content-sending helpers deny before credentials or requests", () => {
  const scripts = join(REPO_ROOT, ".agents/scripts");
  const env = { ...process.env, AIDEVOPS_RUNTIME_POLICY: "local-only" };
  for (const file of ["video-gen-helper.sh", "eeat-score-helper.sh", "email-signature-parser-helper.sh"]) {
    const result = spawnSync("bash", [join(scripts, file), "help"], { encoding: "utf8", env });
    assert.equal(result.status, 64, result.stderr);
    assert.match(result.stderr + result.stdout, /VAULT_POLICY_DENIED/);
    assert.ok(!(result.stderr + result.stdout).includes(SENTINEL));
  }
  for (const fn of ["transcribe_groq", "transcribe_openai", "download_url_audio", "download_youtube_audio"]) {
    // Load the actual script with its harmless help entrypoint, preserving its
    // BASH_SOURCE-based helper resolution, then exercise the sending function.
    const script = 'source "$1" help >/dev/null; "$2" "$3" ignored auto txt ignored';
    const result = spawnSync("bash", ["-c", script, "test", join(scripts, "transcription-helper.sh"), fn, SENTINEL],
      { encoding: "utf8", env: { ...env, SCRIPT_DIR: scripts } });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr + result.stdout, /VAULT_POLICY_DENIED/);
  }
  const python = `import sys; sys.path.insert(0,sys.argv[1]); import email_md_summary as m; m._summarise_with_anthropic(sys.argv[2],sys.argv[2])`;
  for (const binding of ["local-only", "provider -ai"]) {
    const result = spawnSync("python3", ["-c", python, scripts, SENTINEL], { encoding: "utf8", env: { ...env, AIDEVOPS_RUNTIME_POLICY: binding } });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /VAULT_POLICY_DENIED/);
    assert.ok(!result.stderr.includes(SENTINEL));
  }
  const embeddings = spawnSync("bash", ["-c", 'source "$1/shared-constants.sh"; source "$1/memory-embeddings-helper-engine.sh"; get_provider() { printf openai; }; check_deps', "test", scripts],
    { encoding: "utf8", env: { ...env, SCRIPT_DIR: scripts } });
  assert.equal(embeddings.status, 64, embeddings.stderr);
  assert.match(embeddings.stderr, /VAULT_POLICY_DENIED/);
});

test("generated embedding engine denies direct invocation, including malformed opt-outs", () => {
  const scripts = join(REPO_ROOT, ".agents/scripts");
  const home = mkdtempSync(join(tmpdir(), "aidevops-embedding-policy-"));
  try {
    const generated = join(home, "engine.py");
    const writer = spawnSync("bash", ["-c", 'source "$1/memory-embeddings-helper-engine.sh"; PYTHON_SCRIPT="$2"; _write_python_policy_gate', "test", scripts, generated],
      { encoding: "utf8", env: { ...process.env, SCRIPT_DIR: scripts } });
    assert.equal(writer.status, 0, writer.stderr);
    const python = 'import os,sys; exec(open(sys.argv[1]).read()); check_embedding_policy()';
    for (const binding of ["local-only", "provider -ai"]) {
      const result = spawnSync("python3", ["-c", python, generated], {
        encoding: "utf8", env: { ...process.env, AIDEVOPS_RUNTIME_POLICY: binding },
      });
      assert.equal(result.status, 64, result.stderr);
      assert.match(result.stderr, /VAULT_POLICY_DENIED/);
    }
    const unbound = spawnSync("python3", ["-c", python, generated], {
      encoding: "utf8", env: { ...process.env, AIDEVOPS_RUNTIME_POLICY: "" },
    });
    assert.equal(unbound.status, 0, unbound.stderr);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("bound Ollama helper uses loopback without proxies or redirect fallback", async () => {
  const received = [];
  const server = createServer((request, response) => {
    let body = "";
    request.on("data", (data) => { body += data; });
    request.on("end", () => {
      received.push({ url: request.url, body });
      if (request.url === "/redirect") {
        response.writeHead(302, { Location: `http://0.0.0.0:${server.address().port}/external` });
        response.end();
      } else response.end(JSON.stringify({ response: "Local summary" }));
    });
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  try {
    const scripts = join(REPO_ROOT, ".agents/scripts");
    const python = 'import sys; sys.path.insert(0,sys.argv[1]); import email_md_summary as m; print(m._summarise_with_ollama(sys.argv[2],"subject"))';
    const env = { ...process.env, AIDEVOPS_RUNTIME_POLICY: "local-only",
      HTTP_PROXY: "http://0.0.0.0:1", HTTPS_PROXY: "http://0.0.0.0:1", NO_PROXY: "" };
    const local = `http://127.0.0.1:${server.address().port}`;
    const result = await childResult("python3", ["-c", python, scripts, SENTINEL], { ...env, OLLAMA_API_URL: local + "/local" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), "Local summary");
    assert.ok(received[0].body.includes(SENTINEL));
    const redirect = await childResult("python3", ["-c", python, scripts, SENTINEL], { ...env, OLLAMA_API_URL: local + "/redirect" });
    assert.notEqual(redirect.status, 0);
    assert.match(redirect.stderr, /VAULT_POLICY_DENIED/);
    const remote = await childResult("python3", ["-c", python, scripts, SENTINEL], { ...env, OLLAMA_API_URL: `http://0.0.0.0:${server.address().port}/external` });
    assert.notEqual(remote.status, 0);
    assert.match(remote.stderr, /VAULT_POLICY_DENIED/);
    assert.deepEqual(received.map((entry) => entry.url), ["/local", "/redirect"]);
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose));
  }
});

test("launcher disables remote OTEL before host startup, preserving unbound environment", () => {
  const launcher = join(REPO_ROOT, ".agents/scripts/opencode-launcher-helper.sh");
  const script = 'source "$1" --help >/dev/null; printf "%s|%s|%s" "${OTEL_SDK_DISABLED:-}" "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" "${OTEL_TRACES_EXPORTER:-}"';
  const base = { ...process.env, OTEL_SDK_DISABLED: "false", OTEL_TRACES_EXPORTER: "otlp", OTEL_EXPORTER_OTLP_ENDPOINT: "https://api.example.com/" + SENTINEL };
  const bound = spawnSync("bash", ["-c", script, "test", launcher], { encoding: "utf8", env: { ...base, AIDEVOPS_RUNTIME_POLICY: "local-only" } });
  assert.equal(bound.status, 0, bound.stderr);
  assert.equal(bound.stdout, "true||none");
  const unbound = spawnSync("bash", ["-c", script, "test", launcher], { encoding: "utf8", env: { ...base, AIDEVOPS_RUNTIME_POLICY: "" } });
  assert.equal(unbound.status, 0, unbound.stderr);
  assert.equal(unbound.stdout, "false|" + base.OTEL_EXPORTER_OTLP_ENDPOINT + "|otlp");
});

test("MCP approvals cannot cross project configuration boundaries", () => {
  const policy = loadLocalOnlyPolicy({ AIDEVOPS_RUNTIME_POLICY: "local-only" });
  const localProject = join(REPO_ROOT, "project-local");
  const remoteProject = join(REPO_ROOT, "project-remote");
  captureLocalOnlyMcpConfig({ same: { type: "local" } }, localProject);
  captureLocalOnlyMcpConfig({ same: { type: "remote", url: "https://api.example.com" } }, remoteProject);
  assert.doesNotThrow(() => assertLocalOnlyToolCall("same_send", {}, policy, localProject));
  assert.throws(() => assertLocalOnlyToolCall("same_send", { cwd: localProject }, policy, remoteProject), /VAULT_POLICY_DENIED/);
});

test("conversation env -i preserves binding and telemetry protection at the actual child boundary", () => {
  const home = mkdtempSync(join(tmpdir(), "aidevops-conversation-binding-"));
  const launcher = join(REPO_ROOT, ".agents/scripts/opencode-launcher-helper.sh");
  const executable = join(home, "fake-opencode");
  try {
    writeFileSync(executable, '#!/usr/bin/env bash\nprintf "%s|%s|%s" "${AIDEVOPS_RUNTIME_POLICY:-}" "${OTEL_SDK_DISABLED:-}" "${OTEL_TRACES_EXPORTER:-}"\n', { mode: 0o700 });
    const script = `source "$1" --help >/dev/null
      create_conversation_runtime() { printf -v "$2" '%s' "$TEST_RUNTIME"; return 0; }
      copy_auth_json() { return 0; }
      cleanup_conversation_runtime() { return 0; }
      verify_conversation_effective_config() { return 0; }
      run_conversation_session ignored "$TEST_RUNTIME" "$2"`;
    for (const [binding, expected] of [["local-only", "local-only|true|none"], ["", "||"]]) {
      const result = spawnSync("bash", ["-c", script, "test", launcher, executable], {
        encoding: "utf8", env: { ...process.env, AIDEVOPS_RUNTIME_POLICY: binding, TEST_RUNTIME: home },
      });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, expected);
    }
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});
