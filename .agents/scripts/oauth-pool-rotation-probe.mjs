#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawnSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as vm from "node:vm";

const script = fileURLToPath(import.meta.url);
const realModules = new Set([
  "provider-auth.mjs", "provider-auth-pool.mjs", "provider-auth-pool-recovery.mjs",
]);

// Substitute specifiers BEFORE filesystem resolution. Neither the pool store
// nor request-transform dependency graph is ever opened or imported.
const poolStub = `
export const accounts = [0, 1].map(i => ({
  email: 'dummy-' + i + '@example.invalid', access: 'dummy-access-' + i,
  refresh: 'dummy-refresh-' + i, expires: Date.now() + 3600000,
  status: 'idle', cooldownUntil: 0, lastUsed: ''
}));
export const patches = [];
export function getAccounts(provider) {
  if (provider !== 'anthropic') throw Error('Unexpected provider');
  return accounts;
}
export async function ensureValidToken(provider, account) {
  if (provider !== 'anthropic' || !accounts.includes(account)) throw Error('Unexpected refresh');
  return account.access;
}
export function patchAccount(provider, email, patch) {
  const account = getAccounts(provider).find(a => a.email === email);
  if (!account) throw Error('Unknown dummy account');
  patches.push({ email, patch });
  Object.assign(account, patch);
}
export function normalizeExpiredCooldowns() {}
export function markAuthRefreshFailure() { throw Error('Unexpected auth refresh failure'); }
`;

const requestStub = `
export function buildRequestHeaders(input, init, token) {
  const headers = new Headers(init?.headers);
  headers.set('authorization', 'Bearer ' + token);
  return headers;
}
export function transformRequestBody(body) { return body; }
export function addBetaQueryParam(input) { return input; }
export function transformResponseStream(response) { return response; }
`;

const harness = `
import { createProviderAuthHook } from './provider-auth.mjs';
import { accounts, patches } from './oauth-pool.mjs';
export const results = [];
function check(name, condition) {
  results.push({ name, pass: Boolean(condition) });
}
async function scenario(name, initial, limited, cooling = false) {
  for (const account of accounts) {
    Object.assign(account, { status: 'idle', cooldownUntil: 0, lastUsed: '' });
  }
  patches.length = 0;
  const alternate = 1 - initial;
  if (cooling) accounts[alternate].cooldownUntil = Date.now() + 120000;
  const calls = [];
  const writes = [];
  const body = JSON.stringify({ messages: [{ role: 'user', content: 'dummy' }] });
  globalThis.fetch = async (_input, init) => {
    if (calls.length >= 3) throw Error('Attempt budget exceeded');
    const index = accounts.findIndex(a => 'Bearer ' + a.access === init.headers.get('authorization'));
    if (index < 0) throw Error('Non-dummy authorization');
    calls.push({ index, body: init.body });
    return new Response('simulated', {
      status: limited.includes(index) ? 429 : 200, headers: { 'retry-after': '17' }
    });
  };
  try {
    const hook = createProviderAuthHook({ auth: { async set(payload) { writes.push(payload); } } });
    const auth = await hook.loader(async () => ({ type: 'oauth', ...accounts[initial] }), { models: { dummy: {} } });
    const response = await auth.fetch('https://example.invalid/v1/messages', { method: 'POST', body });
    const rotates = !cooling;
    const sequence = rotates ? [initial, alternate] : [initial];
    check(name + ': bounded account sequence and returned status',
      JSON.stringify(calls.map(c => c.index)) === JSON.stringify(sequence) &&
      response.status === (limited.includes(alternate) || cooling ? 429 : 200));
    check(name + ': identical request body', calls.every(c => c.body === body));
    check(name + ': SDK auth update', rotates ?
      writes.length === 1 && writes[0].path.id === 'anthropic' &&
      writes[0].body.access === accounts[alternate].access &&
      writes[0].body.refresh === accounts[alternate].refresh &&
      writes[0].body.type === 'oauth' : writes.length === 0);
    const expectedLimited = cooling ? [initial] : sequence.filter(i => limited.includes(i));
    check(name + ': Retry-After cooldown', expectedLimited.every(i =>
      patches.some(p => p.email === accounts[i].email && p.patch.status === 'rate-limited' &&
        p.patch.cooldownUntil === Date.now() + 17000)));
    if (!cooling && !limited.includes(alternate)) {
      calls.length = 0;
      const next = await auth.fetch('https://example.invalid/v1/messages', { method: 'POST', body });
      check(name + ': replacement affinity', next.status === 200 && calls.length === 1 &&
        calls[0].index === alternate && writes.length === 1);
    }
  } catch (error) {
    results.push({ name: name + ': scenario', pass: false, error: String(error.message) });
  }
}
await scenario('first account limited', 0, [0]);
await scenario('second account limited', 1, [1]);
await scenario('both accounts limited (expected 429)', 0, [0, 1]);
await scenario('alternate cooling (expected 429)', 0, [0], true);
`;

async function runIsolated(pluginDir) {
  if (typeof vm.SourceTextModule !== "function" || typeof globalThis.Response !== "function") {
    throw new Error("Unsupported Node: requires Node.js 18+ and --experimental-vm-modules");
  }
  const root = realpathSync(pluginDir);
  // VM is a capability guard for trusted installed code, not a security sandbox
  // for hostile JavaScript. No real process/env, fs, network or SDK is supplied.
  const context = vm.createContext({
    Headers, Request, Response,
    console: { error() {} },
    process: { env: {} },
  }, { codeGeneration: { strings: false, wasm: false } });
  vm.runInContext(`
    const RealDate = Date;
    globalThis.Date = class extends RealDate {
      constructor(...args) { super(...(args.length ? args : [1800000000000])); }
      static now() { return 1800000000000; }
    };
    globalThis.fetch = () => { throw Error('Unconfigured offline fetch'); };
    globalThis.setTimeout = () => { throw Error('Unexpected exhaustion wait'); };
  `, context, { timeout: 1000 });
  const modules = new Map();
  function moduleFor(name) {
    if (modules.has(name)) return modules.get(name);
    let source;
    if (name === "oauth-pool.mjs") source = poolStub;
    else if (name === "provider-auth-request.mjs") source = requestStub;
    else if (name === "probe-harness") source = harness;
    else {
      if (!realModules.has(name)) throw new Error(`Isolation denied module: ${name}`);
      const path = realpathSync(resolve(root, name));
      if (path !== resolve(root, name)) throw new Error("Isolation denied source-file symlink");
      source = readFileSync(path, "utf8");
    }
    const module = new vm.SourceTextModule(source, {
      context, identifier: name,
      importModuleDynamically() { throw new Error("Isolation denied dynamic import"); },
    });
    modules.set(name, module);
    return module;
  }
  const entry = moduleFor("probe-harness");
  await entry.link((specifier) => {
    if (!/^\.\/[a-z-]+\.mjs$/.test(specifier)) throw new Error("Isolation denied dependency specifier");
    return moduleFor(specifier.slice(2));
  });
  await entry.evaluate({ timeout: 1000 });
  const results = entry.namespace.results;
  for (const result of results) {
    console.log(`${result.pass ? "PASS" : "FAIL"} ${result.name}${result.error ? `: ${result.error}` : ""}`);
  }
  if (results.length !== 18 || results.some(result => !result.pass)) {
    throw new Error("Offline scenario contract failed");
  }
}

try {
  const args = process.argv.slice(2);
  if (args[0] === "--isolated" && args.length === 2) {
    await runIsolated(args[1]);
  } else {
    if (args.length !== 1 || args[0] !== "anthropic") {
      throw new Error("Usage: probe-rotation anthropic (offline simulated diagnostic)");
    }
    console.log("OFFLINE / SIMULATED Anthropic rotation diagnostic — not live end-to-end failover");
    console.log("Real provider hook, selection and recovery; dummy pool/SDK/network; request transforms substituted");
    const pluginDir = resolve(dirname(script), "../plugins/opencode-aidevops");
    // No inherited credentials, NODE_OPTIONS, preloads, location overrides or proxies.
    const child = spawnSync(process.execPath, [
      "--no-warnings", "--experimental-vm-modules", script, "--isolated", pluginDir,
    ], { env: {}, encoding: "utf8", timeout: 10000, maxBuffer: 128 * 1024 });
    if (child.stdout) process.stdout.write(child.stdout);
    if (child.status !== 0 || child.error) {
      if (child.stderr) process.stderr.write(child.stderr);
      throw new Error(child.error?.code === "ETIMEDOUT" ? "Offline probe timed out" : "Isolated probe failed (no live fallback)");
    }
    console.log("PASS overall offline simulated rotation (18 assertions)");
  }
} catch (error) {
  console.error(`FAIL offline probe: ${error.message}`);
  process.exitCode = 1;
}
