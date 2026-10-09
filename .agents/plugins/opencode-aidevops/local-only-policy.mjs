// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Operator-bound local-only egress gate for interactive sessions (GH#34125).
//
// #aidevops:trust-boundary — the binding comes only from the launch
// environment (AIDEVOPS_RUNTIME_POLICY) and is read once, at plugin init, then
// deep-frozen. Model output, tool arguments, chat text and later process.env
// mutation cannot set or clear it. When bound, every model request whose
// provider is not local fails closed before any bytes leave the device.
// Unbound sessions are unaffected.

import { readFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const RUNTIME_POLICY_ENV = "AIDEVOPS_RUNTIME_POLICY";
export const VAULT_POLICY_DENIED = "VAULT_POLICY_DENIED";
// Fixed system locations only; never resolve an executable from model-controlled
// PATH or a working directory. NixOS does not provide /usr/bin/curl.
export const LOCAL_ONLY_CURL = existsSync("/usr/bin/curl")
  ? "/usr/bin/curl" : "/run/current-system/sw/bin/curl";

// Shared with scripts/vault-data-policy-helper.sh; never fork this list.
export const LOCAL_PROVIDERS_FILE = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../configs/local-ai-providers.conf",
);

const LOCAL_POLICY_TOKENS = new Set(["local-only", "local-llm-only", "local-ai"]);
// Explicit opt-out vocabulary from reference/vault.md; anything else binds.
const UNBOUND_POLICY_TOKENS = new Set(["provider-ai", "provider-allowed", "provider-ai-approved"]);

export class LocalOnlyPolicyError extends Error {
  constructor(message) {
    super(`${VAULT_POLICY_DENIED}: ${message}`);
    this.name = "LocalOnlyPolicyError";
    this.code = VAULT_POLICY_DENIED;
  }
}

/**
 * Parse the local-provider list. Comments and blank lines are ignored.
 * @param {string} text
 * @returns {string[]}
 */
export function parseLocalProviders(text) {
  return String(text || "")
    .split(/\r?\n/)
    .map((line) => line.replace(/#.*/, "").replace(/\s+/g, ""))
    .filter(Boolean);
}

function readLocalProviders(file, readFile) {
  try {
    return parseLocalProviders(readFile(file, "utf8"));
  } catch {
    // Missing/unreadable list: nothing is local, so bound sessions fail closed.
    return [];
  }
}

/**
 * Build a frozen policy from a launch environment snapshot.
 * @param {Record<string, string|undefined>} env
 * @param {{ providersFile?: string, readFile?: Function }} [options]
 * @returns {Readonly<{ bound: boolean, policy: string, reason: string, localProviders: readonly string[] }>}
 */
export function loadLocalOnlyPolicy(env, options = {}) {
  const raw = String(env?.[RUNTIME_POLICY_ENV] ?? "").trim().toLowerCase();
  let bound = false;
  let reason = "unbound";
  if (LOCAL_POLICY_TOKENS.has(raw)) {
    bound = true;
    reason = "declared";
  } else if (raw && !UNBOUND_POLICY_TOKENS.has(raw)) {
    bound = true;
    reason = "unrecognised-policy-fails-closed";
  }
  const localProviders = bound
    ? readLocalProviders(options.providersFile || LOCAL_PROVIDERS_FILE, options.readFile || readFileSync)
    : [];
  return Object.freeze({
    bound,
    policy: raw,
    reason,
    localProviders: Object.freeze(localProviders),
  });
}

let activePolicy;

/**
 * Bind this process to the launch environment once. Later calls return the
 * first binding unchanged, whatever they pass.
 * @param {Record<string, string|undefined>} [env]
 * @returns {ReturnType<typeof loadLocalOnlyPolicy>}
 */
export function initLocalOnlyPolicy(env = process.env) {
  if (!activePolicy) activePolicy = loadLocalOnlyPolicy(env);
  return activePolicy;
}

/** @returns {ReturnType<typeof loadLocalOnlyPolicy>} */
export function activeLocalOnlyPolicy() {
  return activePolicy || initLocalOnlyPolicy();
}

// #aidevops:trust-boundary — populated only by host configuration hooks, never
// by tool arguments. Copy primitive fields so later config mutation cannot turn
// a previously approved local entry into a remote destination.
const mcpConfigurations = new Map();
export function captureLocalOnlyMcpConfig(entries, directory = process.cwd()) {
  const snapshot = Object.fromEntries(Object.entries(entries || {}).map(([name, entry]) =>
    [name, Object.freeze({ type: entry?.type, url: entry?.url })]));
  mcpConfigurations.set(resolve(directory), Object.freeze(snapshot));
}

export function assertLocalOnlyToolDestination(allowed, policy = activeLocalOnlyPolicy()) {
  if (policy.bound && !allowed) {
    throw new LocalOnlyPolicyError("Tool egress was blocked before execution by the local-only session binding.");
  }
}

export function assertLocalOnlyMcp(name, policy = activeLocalOnlyPolicy(), directory = process.cwd()) {
  const entry = mcpConfigurations.get(resolve(directory))?.[name];
  assertLocalOnlyToolDestination(entry?.type === "local"
    || (entry?.type === "remote" && isLoopbackDestination(entry.url)), policy);
}

const LOCAL_NATIVE_TOOLS = new Set([
  "read", "grep", "glob", "list", "write", "edit", "apply_patch", "todowrite", "todoread",
  "task", "aidevops_hook_status", "aidevops_pre_edit_check",
]);

// No shell denylist: opaque programs can always open sockets or clear their
// environment. This single literal invocation disables curlrc, proxies and
// redirects; a URL cannot inject options, shell syntax or another destination.
export function isLocalOnlyCurlArgv(argv) {
  if (!Array.isArray(argv) || argv.length !== 10) return false;
  const prefix = [LOCAL_ONLY_CURL, "--disable", "--noproxy", "*", "--proxy", "", "--max-time", "30", "--url"];
  if (!prefix.every((part, index) => argv[index] === part)) return false;
  const url = argv[9];
  return typeof url === "string" && /^[a-zA-Z0-9:/?&=._%+\[\]-]+$/.test(url)
    && isLoopbackDestination(url) && !new URL(url).username && !new URL(url).password;
}

function canonicalLocalCurl(argv) {
  if (!Array.isArray(argv) || argv.length !== 2 || argv[0] !== "curl") return argv;
  const canonical = [LOCAL_ONLY_CURL, "--disable", "--noproxy", "*", "--proxy", "", "--max-time", "30", "--url", argv[1]];
  return isLocalOnlyCurlArgv(canonical) ? canonical : argv;
}

export function assertLocalOnlyToolCall(tool, args = {}, policy = activeLocalOnlyPolicy(), directory = process.cwd()) {
  if (!policy.bound) return;
  const name = String(tool || "").toLowerCase();
  if (name === "bash" || name === "functions_bash") {
    const simple = /^curl (?:'([^']+)'|([a-zA-Z0-9:/?=._%+\[\]-]+))$/.exec(args.command || "");
    if (simple) {
      const canonical = canonicalLocalCurl(["curl", simple[1] || simple[2]]);
      if (isLocalOnlyCurlArgv(canonical)) {
        args.command = `${LOCAL_ONLY_CURL} --disable --noproxy '*' --proxy '' --max-time 30 --url '${canonical[9]}'`;
      }
    }
    const match = /^(\/usr\/bin\/curl|\/run\/current-system\/sw\/bin\/curl) --disable --noproxy '\*' --proxy '' --max-time 30 --url '([^']+)'$/.exec(args.command || "");
    assertLocalOnlyToolDestination(Boolean(match) && isLocalOnlyCurlArgv([
      match[1], "--disable", "--noproxy", "*", "--proxy", "", "--max-time", "30", "--url", match[2],
    ]), policy);
    return;
  }
  if (name.endsWith("aidevops_bounded_operation")) {
    if (args.action === "start") {
      args.command = canonicalLocalCurl(args.command);
      if (args.restoration_command) args.restoration_command = canonicalLocalCurl(args.restoration_command);
    }
    const safeControl = ["status", "output", "cancel"].includes(args.action);
    const safeStart = args.action === "start" && isLocalOnlyCurlArgv(args.command)
      && (!args.restoration_command || isLocalOnlyCurlArgv(args.restoration_command));
    assertLocalOnlyToolDestination(safeControl || safeStart, policy);
    return;
  }
  if (name === "aidevops_mcp") {
    if (args.action === "connect") assertLocalOnlyMcp(args.name, policy, directory);
    return;
  }
  // Longest prefix first avoids ambiguous user server names (foo vs foo_bar).
  const server = Object.keys(mcpConfigurations.get(resolve(directory)) || {}).sort((a, b) => b.length - a.length)
    .find((key) => name.startsWith(`${key.toLowerCase()}_`) || name.startsWith(`mcp__${key.toLowerCase()}__`));
  if (server) return assertLocalOnlyMcp(server, policy, directory);
  assertLocalOnlyToolDestination(LOCAL_NATIVE_TOOLS.has(name), policy);
}

/**
 * @param {ReturnType<typeof loadLocalOnlyPolicy>} policy
 * @param {string} providerID
 * @returns {boolean}
 */
export function isLocalProvider(policy, providerID) {
  const provider = String(providerID || "").trim();
  return Boolean(provider) && (policy?.localProviders || []).includes(provider);
}

/**
 * Provider ID from V1 (chat.params) or V2 (session hook) input shapes.
 * @param {object} input
 * @returns {string}
 */
export function requestProviderID(input) {
  const explicit = input?.model?.providerID || input?.provider?.info?.id || input?.provider?.id;
  if (explicit) return String(explicit);
  const model = typeof input?.model === "string" ? input.model : "";
  const separator = model.indexOf("/");
  return separator > 0 ? model.slice(0, separator) : "";
}

/**
 * Endpoint the request will actually reach. V2 http.request carries the real
 * Request; V1 chat.params mirrors OpenCode's resolveSDK precedence: a
 * non-empty provider.options.baseURL, else model.api.url.
 * @param {object} input
 * @returns {string}
 */
export function requestDestination(input) {
  const requestUrl = input?.request?.url;
  if (typeof requestUrl === "string" && requestUrl) return requestUrl;
  const baseURL = input?.provider?.options?.baseURL;
  if (typeof baseURL === "string" && baseURL !== "") return baseURL;
  const apiUrl = input?.model?.api?.url;
  return typeof apiUrl === "string" ? apiUrl : "";
}

/**
 * True only for http(s) URLs whose host is literal loopback. Unparseable
 * URLs, unresolved ${VAR} templates, LAN hosts and 0.0.0.0 fail closed.
 * @param {string} destination
 * @returns {boolean}
 */
export function isLoopbackDestination(destination) {
  let url;
  try {
    url = new URL(String(destination || ""));
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  const host = url.hostname.toLowerCase();
  return host === "localhost" || host === "[::1]" || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host);
}

// Surfaces whose input names the endpoint; V2 "context" does not, so its
// destination is enforced at the later http.request boundary.
const DESTINATION_SURFACES = new Set(["chat", "http"]);

function deny(policy, detail) {
  throw new LocalOnlyPolicyError(
    `${RUNTIME_POLICY_ENV}=${policy.policy} binds this session to local AI; ${detail} was blocked before sending. `
      + "Select a local model, or relaunch without the binding if this work may use a remote provider.",
  );
}

/**
 * Throw a content-free denial before a non-local request leaves the device.
 * Two independent checks: the provider ID must be listed as local, and, where
 * the surface exposes it, the endpoint must be loopback, so a remote endpoint
 * configured under a local provider name is still refused. An unidentifiable
 * provider or endpoint is treated as non-local.
 * @param {ReturnType<typeof loadLocalOnlyPolicy>} policy
 * @param {object} input hook input carrying the target model/provider
 * @param {string} surface request boundary name, for the operator message only
 */
export function assertLocalOnlyEgress(policy, input, surface) {
  if (!policy?.bound) return;
  const providerID = requestProviderID(input);
  if (!isLocalProvider(policy, providerID)) {
    deny(policy, `${surface} request to provider "${providerID || "unknown"}"`);
  }
  if (DESTINATION_SURFACES.has(surface) && !isLoopbackDestination(requestDestination(input))) {
    deny(policy, `${surface} request for local provider "${providerID}" to a non-loopback or unknown endpoint`);
  }
}

const LOCAL_FAILURE_PATTERNS = [
  [/ECONNREFUSED|connection refused/i, "local_backend_connection_refused"],
  [/ETIMEDOUT|timeout|timed out/i, "local_backend_timeout"],
  [/model.identity.mismatch/i, "local_backend_model_identity_mismatch"],
];

/** Content-free failed-check names; never return raw backend diagnostics. */
export function localFailureCheck(error) {
  const message = String(error?.data?.message || error?.message || "");
  const code = String(error?.code || error?.data?.code || "");
  if (code === VAULT_POLICY_DENIED || /VAULT_POLICY_DENIED/.test(message)) return "vault_policy_denied";
  if (Number(error?.data?.statusCode) === 404) return "local_backend_http_404";
  const match = LOCAL_FAILURE_PATTERNS.find(([pattern]) => pattern.test(`${code} ${message}`));
  return match?.[1] || null;
}
