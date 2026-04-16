/**
 * OAuth Pool — Token Endpoint Fetch & Cooldown (t2128 hotfix)
 *
 * Contains: curl-based token endpoint fetch for all providers (Anthropic,
 * OpenAI, Google), per-provider cooldown state, rate-limit parsing,
 * User-Agent strings, and cooldown accessor functions.
 *
 * Extracted from the pre-decomposition oauth-pool.mjs. PR #19229 referenced
 * this file in imports but never created it, breaking all new sessions.
 *
 * @module oauth-pool-token-endpoint
 */

import { execFileSync } from "child_process";
import {
  ANTHROPIC_TOKEN_ENDPOINT, OPENAI_TOKEN_ENDPOINT, GOOGLE_TOKEN_ENDPOINT,
  TOKEN_ENDPOINT_COOLDOWN_MS,
} from "./oauth-pool-constants.mjs";

// ---------------------------------------------------------------------------
// CLI version detection (for User-Agent strings)
// ---------------------------------------------------------------------------

const FALLBACK_CLAUDE_VERSION = "2.1.80";
const FALLBACK_OPENCODE_VERSION = "1.2.27";

function detectCliVersion(binaries, fallback) {
  for (const bin of binaries) {
    try {
      const raw = execFileSync(bin, ["--version"], { timeout: 3000, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] }).trim();
      const match = raw.match(/^(\d+\.\d+\.\d+)/);
      if (match) return match[1];
    } catch { /* not installed */ }
  }
  return fallback;
}

const DETECTED_CLAUDE_VERSION = detectCliVersion(["claude"], FALLBACK_CLAUDE_VERSION);
const DETECTED_OPENCODE_VERSION = detectCliVersion(["opencode", "oc"], FALLBACK_OPENCODE_VERSION);

export const ANTHROPIC_USER_AGENT = `claude-cli/${DETECTED_CLAUDE_VERSION} (external, cli)`;
export const OPENCODE_USER_AGENT = `opencode/${DETECTED_OPENCODE_VERSION}`;

export function getAnthropicUserAgent() {
  return ANTHROPIC_USER_AGENT;
}

// ---------------------------------------------------------------------------
// Per-provider cooldown state (in-memory, process-lifetime)
// ---------------------------------------------------------------------------

let tokenEndpointCooldownUntil = 0;
let openaiTokenEndpointCooldownUntil = 0;
let cursorProxyCooldownUntil = 0;
let googleTokenEndpointCooldownUntil = 0;

// ---------------------------------------------------------------------------
// Cooldown accessors (exported for oauth-pool-display.mjs / oauth-pool.mjs)
// ---------------------------------------------------------------------------

export function getEndpointCooldownValue(prov) {
  const map = { anthropic: tokenEndpointCooldownUntil, openai: openaiTokenEndpointCooldownUntil, google: googleTokenEndpointCooldownUntil };
  return map[prov] ?? cursorProxyCooldownUntil;
}

export function resetEndpointCooldown(prov) {
  const setters = {
    cursor: () => { const g = cursorProxyCooldownUntil > Date.now(); cursorProxyCooldownUntil = 0; return g; },
    openai: () => { const g = openaiTokenEndpointCooldownUntil > Date.now(); openaiTokenEndpointCooldownUntil = 0; return g; },
    google: () => { const g = googleTokenEndpointCooldownUntil > Date.now(); googleTokenEndpointCooldownUntil = 0; return g; },
    anthropic: () => { const g = tokenEndpointCooldownUntil > Date.now(); tokenEndpointCooldownUntil = 0; return g; },
  };
  return (setters[prov] || setters.anthropic)();
}

// ---------------------------------------------------------------------------
// Rate-limit / cooldown helpers
// ---------------------------------------------------------------------------

function parseRetryAfterCooldown(retryAfter) {
  if (!retryAfter) return TOKEN_ENDPOINT_COOLDOWN_MS;
  const secs = Number.parseInt(retryAfter, 10);
  const ms = Number.isFinite(secs) ? secs * 1000 : Math.max((Date.parse(retryAfter) || 0) - Date.now(), 0);
  return Math.max(ms, TOKEN_ENDPOINT_COOLDOWN_MS);
}

const COOLDOWN_RESPONSE = {
  ok: false, status: 429, statusText: "Rate Limited (cooldown)",
  headers: { get() { return null; } },
  async json() { return { error: "Rate limited (cooldown)" }; },
  async text() { return "Rate limited (cooldown)"; },
};

function checkCooldownGate(cooldownUntil, context, providerLabel) {
  if (cooldownUntil <= Date.now()) return null;
  console.error(`[aidevops] OAuth pool: ${context} skipped — ${providerLabel} rate limited, ${Math.ceil((cooldownUntil - Date.now()) / 60000)}m remaining.`);
  return COOLDOWN_RESPONSE;
}

// ---------------------------------------------------------------------------
// Curl-based token endpoint fetch (avoids Bun's automatic header injection)
// ---------------------------------------------------------------------------

function parseCurlResponse(raw) {
  const lines = raw.trimEnd().split("\n");
  const statusCode = parseInt(lines.pop(), 10) || 500;
  const fullOutput = lines.join("\n");
  const splitIdx = fullOutput.indexOf("\r\n\r\n");
  const headers = {};
  let body = fullOutput;
  if (splitIdx !== -1) {
    for (const line of fullOutput.substring(0, splitIdx).split("\r\n")) {
      const ci = line.indexOf(":");
      if (ci > 0) headers[line.substring(0, ci).trim().toLowerCase()] = line.substring(ci + 1).trim();
    }
    body = fullOutput.substring(splitIdx + 4);
  }
  return { statusCode, headers, body };
}

const STATUS_TEXT_MAP = { 200: "OK", 400: "Bad Request", 401: "Unauthorized", 429: "Too Many Requests" };
function statusCodeToText(sc) { return STATUS_TEXT_MAP[sc] || `HTTP ${sc}`; }

function buildCurlResponseObject(p) {
  return {
    ok: p.statusCode >= 200 && p.statusCode < 300, status: p.statusCode, statusText: statusCodeToText(p.statusCode),
    headers: { get(k) { return p.headers[k.toLowerCase()] ?? null; } },
    async json() { return JSON.parse(p.body); }, async text() { return p.body; },
  };
}

function buildCurlErrorResponse(reason) {
  return {
    ok: false, status: 500, statusText: "curl failed",
    headers: { get() { return null; } },
    async json() { return { error: reason }; }, async text() { return reason; },
  };
}

function curlTokenEndpoint(url, options, context) {
  const args = ["-sS", "-i", "-w", "\n%{http_code}", "-X", "POST",
    "-H", `Content-Type: ${options.contentType || "application/json"}`,
    "-H", `User-Agent: ${options.headers["User-Agent"]}`,
    "--data-binary", "@-", "--max-time", "15", url];
  try {
    const raw = execFileSync("curl", args, { encoding: "utf-8", timeout: 20_000, input: options.body });
    return buildCurlResponseObject(parseCurlResponse(raw));
  } catch (err) {
    const reason = err?.code || `exit ${err?.status ?? "unknown"}`;
    console.error(`[aidevops] OAuth pool: ${context} curl failed (${reason})`);
    return buildCurlErrorResponse(reason);
  }
}

// ---------------------------------------------------------------------------
// Generic provider fetch with cooldown gate + 429 handling
// ---------------------------------------------------------------------------

async function fetchProviderTokenEndpoint(opts, context) {
  const gated = checkCooldownGate(opts.cooldownUntil, context, opts.providerLabel);
  if (gated) return gated;

  const response = curlTokenEndpoint(opts.url, {
    headers: { "User-Agent": opts.userAgent },
    body: opts.body,
    contentType: opts.contentType,
  }, context);

  if (response.status === 429) {
    const cdMs = parseRetryAfterCooldown(response.headers.get("retry-after"));
    opts.setCooldown(Date.now() + cdMs);
    console.error(`[aidevops] OAuth pool: ${context} rate limited by ${opts.providerLabel}. Cooldown ${Math.ceil(cdMs / 60000)}m.`);
  } else if (!response.ok) {
    console.error(`[aidevops] OAuth pool: ${context} failed: HTTP ${response.status}`);
  }

  return response;
}

// ---------------------------------------------------------------------------
// Per-provider fetch functions (public API)
// ---------------------------------------------------------------------------

export async function fetchTokenEndpoint(body, context) {
  return fetchProviderTokenEndpoint({
    url: ANTHROPIC_TOKEN_ENDPOINT,
    userAgent: ANTHROPIC_USER_AGENT,
    body,
    cooldownUntil: tokenEndpointCooldownUntil,
    providerLabel: "Anthropic",
    setCooldown: (until) => { tokenEndpointCooldownUntil = until; },
  }, context);
}

export async function fetchOpenAITokenEndpoint(params, context) {
  return fetchProviderTokenEndpoint({
    url: OPENAI_TOKEN_ENDPOINT,
    userAgent: OPENCODE_USER_AGENT,
    body: params.toString(),
    contentType: "application/x-www-form-urlencoded",
    cooldownUntil: openaiTokenEndpointCooldownUntil,
    providerLabel: "OpenAI",
    setCooldown: (until) => { openaiTokenEndpointCooldownUntil = until; },
  }, context);
}

export async function fetchGoogleTokenEndpoint(body, context) {
  return fetchProviderTokenEndpoint({
    url: GOOGLE_TOKEN_ENDPOINT,
    userAgent: ANTHROPIC_USER_AGENT,
    body,
    cooldownUntil: googleTokenEndpointCooldownUntil,
    providerLabel: "Google",
    setCooldown: (until) => { googleTokenEndpointCooldownUntil = until; },
  }, context);
}
