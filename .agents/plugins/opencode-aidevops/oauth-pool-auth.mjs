/**
 * OAuth Pool — Auth Hooks & Handlers (extracted from oauth-pool.mjs for complexity reduction)
 *
 * Contains: provider auth hooks (anthropic, openai, cursor, google),
 * token exchange handlers, email resolution helpers, PKCE, OAuth callback server,
 * and provider registration.
 *
 * @module oauth-pool-auth
 */

import { createHash, randomBytes } from "crypto";
import { createServer } from "http";
import { execSync } from "child_process";

import {
  getAccounts, upsertAccount, savePendingToken, patchAccount,
  fetchTokenEndpoint, fetchOpenAITokenEndpoint, fetchGoogleTokenEndpoint,
  injectPoolToken, injectOpenAIPoolToken, injectCursorPoolToken, injectGooglePoolToken,
  readCursorAuthJsonCredentials, readCursorStateDbCredentials,
  isCursorAgentAvailable, decodeCursorJWT,
  ANTHROPIC_USER_AGENT, OPENCODE_USER_AGENT,
} from "./oauth-pool.mjs";

// ---------------------------------------------------------------------------
// OAuth constants (static public configuration — duplicated from main module
// to avoid circular dependency via constant exports)
// ---------------------------------------------------------------------------

const ANTHROPIC_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const ANTHROPIC_OAUTH_AUTHORIZE_URL = "https://claude.ai/oauth/authorize";
const ANTHROPIC_REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback";
const ANTHROPIC_OAUTH_SCOPES = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

const OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const OPENAI_ISSUER = "https://auth.openai.com";
const OPENAI_OAUTH_AUTHORIZE_URL = `${OPENAI_ISSUER}/oauth/authorize`;
const OPENAI_REDIRECT_URI = "http://localhost:1455/auth/callback";
const OPENAI_OAUTH_SCOPES = "openid profile email offline_access";

const GOOGLE_CLIENT_ID = "681255809395-oo8ft6t5t0rnmhfqgpnkqtev5b9a2i5j.apps.googleusercontent.com";
const GOOGLE_OAUTH_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_REDIRECT_URI = "urn:ietf:wg:oauth:2.0:oob";
const GOOGLE_OAUTH_SCOPES = "https://www.googleapis.com/auth/generative-language https://www.googleapis.com/auth/cloud-platform openid email profile";

const CURSOR_PROXY_BASE_URL = "http://127.0.0.1:32123/v1";

const OAUTH_CALLBACK_PORT = 1455;
const OAUTH_CALLBACK_TIMEOUT_MS = 300_000;

// ---------------------------------------------------------------------------
// PKCE helpers
// ---------------------------------------------------------------------------

function generatePKCE() {
  const verifier = randomBytes(32).toString("base64url").replace(/[^a-zA-Z0-9\-._~]/g, "").slice(0, 128);
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

// ---------------------------------------------------------------------------
// OAuth callback server
// ---------------------------------------------------------------------------

function startOAuthCallbackServer() {
  let resolveCode, rejectCode, server, timeoutId, resolveReady;
  const promise = new Promise((resolve, reject) => { resolveCode = resolve; rejectCode = reject; });
  const ready = new Promise((resolve) => { resolveReady = resolve; });
  const escapeHtml = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#039;");

  server = createServer((req, res) => {
    let reqUrl;
    try { reqUrl = new URL(req.url, `http://localhost:${OAUTH_CALLBACK_PORT}`); }
    catch { res.writeHead(400, { "Content-Type": "text/plain" }); res.end("Bad request"); return; }
    if (reqUrl.pathname !== "/auth/callback") { res.writeHead(404, { "Content-Type": "text/plain" }); res.end("Not found"); return; }
    const code = reqUrl.searchParams.get("code");
    const error = reqUrl.searchParams.get("error");
    if (error) {
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(`<!DOCTYPE html><html><body><h2>Authorization Failed</h2><p>${escapeHtml(error)}</p><p>${escapeHtml(reqUrl.searchParams.get("error_description") || "")}</p><p>You can close this tab.</p></body></html>`);
      cleanup(); rejectCode(new Error(`OAuth error: ${error}`));
    } else if (code) {
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(`<!DOCTYPE html><html><body><h2>Authorization Successful</h2><p>The authorization code has been captured. Return to OpenCode.</p><p>You can close this tab.</p></body></html>`);
      cleanup(); resolveCode(code);
    } else {
      res.writeHead(200, { "Content-Type": "text/plain" }); res.end("Waiting for OAuth callback...");
    }
  });
  function cleanup() { if (timeoutId) clearTimeout(timeoutId); if (server) { try { server.close(); } catch { /* ignore */ } } }
  server.on("error", (err) => {
    cleanup();
    if (err.code === "EADDRINUSE") { console.error(`[aidevops] OAuth pool: port ${OAUTH_CALLBACK_PORT} in use`); resolveReady(false); return; }
    console.error(`[aidevops] OAuth pool: callback server error: ${err.message}`);
    resolveReady(false); rejectCode(err);
  });
  server.listen(OAUTH_CALLBACK_PORT, "127.0.0.1", () => { console.error(`[aidevops] OAuth pool: callback server listening on port ${OAUTH_CALLBACK_PORT}`); resolveReady(true); });
  timeoutId = setTimeout(() => { cleanup(); rejectCode(new Error("OAuth callback timeout")); }, OAUTH_CALLBACK_TIMEOUT_MS);
  return { promise, ready, close: cleanup };
}

// ---------------------------------------------------------------------------
// Email prompt builder
// ---------------------------------------------------------------------------

function makeEmailPrompt(provider, placeholder = "you@example.com") {
  return {
    type: "text", key: "email",
    get message() {
      const accounts = getAccounts(provider);
      if (accounts.length === 0) return "Account email (required to match tokens to accounts)";
      return `Existing accounts:\n${accounts.map((a, i) => `  ${i + 1}. ${a.email}`).join("\n")}\nEnter email (existing to re-auth, or new to add)`;
    },
    placeholder,
    validate: (v) => (!v || !v.includes("@")) ? "Please enter a valid email address" : undefined,
  };
}

// ---------------------------------------------------------------------------
// Shared auth hook helpers
// ---------------------------------------------------------------------------

function resolveEmailFromJWTClaims(token, claimKeys = ["email", "sub"]) {
  try {
    const parts = token.split(".");
    if (parts.length < 2) return null;
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf-8"));
    for (const key of claimKeys) {
      const val = key.includes(".") ? key.split(".").reduce((o, k) => o?.[k], payload) : payload[key];
      if (val) return val;
    }
    return null;
  } catch { return null; }
}

async function resolveEmailFromEndpoint(accessToken, endpoint, extraHeaders = {}, emailFields = ["email", "sub"]) {
  try {
    const resp = await fetch(endpoint, { headers: { "Authorization": `Bearer ${accessToken}`, ...extraHeaders }, redirect: "follow" });
    if (!resp.ok) return null;
    const data = await resp.json();
    for (const field of emailFields) {
      const value = field.includes(".") ? field.split(".").reduce((o, k) => o?.[k], data) : data[field];
      if (value) return value;
    }
    return null;
  } catch { return null; }
}

async function resolveAnthropicEmail(accessToken) {
  for (const endpoint of ["https://console.anthropic.com/api/auth/user", "https://api.anthropic.com/api/auth/user"]) {
    const email = await resolveEmailFromEndpoint(accessToken, endpoint, { "User-Agent": ANTHROPIC_USER_AGENT }, ["email", "email_address", "user.email", "account.email"]);
    if (email) { console.error(`[aidevops] OAuth pool: resolved email ${email} from ${endpoint}`); return email; }
  }
  console.error("[aidevops] OAuth pool: could not resolve email from profile API");
  return null;
}

function extractOpenAIAccountId(accessToken) {
  try {
    const parts = accessToken.split(".");
    if (parts.length < 2) return "";
    const p = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf-8"));
    return p.chatgpt_account_id || p["https://api.openai.com/auth"]?.chatgpt_account_id || p.organizations?.[0]?.id || "";
  } catch { return ""; }
}

async function saveAccountAndInject(opts) {
  const { provider, client, email, tokenData, extras = {}, envKey, authId, injectFn, successExtras = {} } = opts;
  const now = new Date().toISOString();
  const saved = upsertAccount(provider, { email, ...tokenData, ...extras, added: now, lastUsed: now, status: "active", cooldownUntil: null });
  if (!saved) {
    savePendingToken(provider, { ...tokenData, ...extras, added: now });
    if (envKey && tokenData.access) process.env[envKey] = tokenData.access;
    if (authId) { try { await client.auth.set({ path: { id: authId }, body: { type: "oauth", ...tokenData, ...extras } }); } catch { /* best-effort */ } }
    return { type: "success", ...tokenData, ...successExtras };
  }
  const total = getAccounts(provider).length;
  console.error(`[aidevops] OAuth pool: added ${email} (${total} account${total === 1 ? "" : "s"} total)`);
  const INSTR = { anthropic: 'Switch to "Anthropic" provider for models.', openai: 'Switch to "OpenAI" provider for models.', cursor: 'Switch to "Cursor" provider for models.', google: "Token injected as GOOGLE_OAUTH_ACCESS_TOKEN." };
  console.error(`[aidevops] OAuth pool: Account added successfully. ${INSTR[provider] || ""}`);
  await injectFn(client);
  return { type: "success", ...tokenData, ...successExtras };
}

async function initCallbackServerSafe() {
  try {
    const server = startOAuthCallbackServer();
    const ready = await server.ready.catch(() => false);
    if (!ready) { console.error("[aidevops] OAuth pool: callback server failed — manual code paste required"); return { server: null, ready: false, code: null }; }
    const state = { server, ready: true, code: null };
    server.promise.then((c) => { state.code = c; }).catch(() => { state.server = null; });
    return state;
  } catch { console.error("[aidevops] OAuth pool: callback server failed — manual code paste required"); return { server: null, ready: false, code: null }; }
}

async function acquireAuthCode(manualCode, cs) {
  const trimmed = manualCode?.trim() || "";
  if (trimmed.length >= 5) { if (cs.server) cs.server.close(); return trimmed; }
  if (cs.code) { console.error("[aidevops] OAuth pool: using auto-captured code"); if (cs.server) cs.server.close(); return cs.code; }
  if (cs.ready && cs.server) {
    try {
      const code = await Promise.race([cs.server.promise, new Promise((_, r) => setTimeout(() => r(new Error("timeout")), 30_000))]);
      console.error("[aidevops] OAuth pool: received code from callback server"); cs.server.close(); return code;
    } catch { console.error("[aidevops] OAuth pool: no code received"); cs.server.close(); return null; }
  }
  if (cs.server) cs.server.close();
  return null;
}

// ---------------------------------------------------------------------------
// Provider callback handlers
// ---------------------------------------------------------------------------

async function handleAnthropicCallback(code, pkce, email, client) {
  const hashIdx = code.indexOf("#");
  const authCode = hashIdx >= 0 ? code.substring(0, hashIdx) : code;
  const state = hashIdx >= 0 ? code.substring(hashIdx + 1) : undefined;
  const result = await fetchTokenEndpoint(JSON.stringify({ code: authCode, state, grant_type: "authorization_code", client_id: ANTHROPIC_CLIENT_ID, redirect_uri: ANTHROPIC_REDIRECT_URI, code_verifier: pkce.verifier }), "token exchange");
  if (!result.ok) return { type: "failed" };
  const json = await result.json();
  let resolvedEmail = email;
  if (resolvedEmail === "unknown" && json.access_token) resolvedEmail = (await resolveAnthropicEmail(json.access_token)) || "unknown";
  return saveAccountAndInject({ provider: "anthropic", client, email: resolvedEmail, tokenData: { refresh: json.refresh_token, access: json.access_token, expires: Date.now() + json.expires_in * 1000 }, envKey: "ANTHROPIC_API_KEY", authId: "anthropic", injectFn: injectPoolToken });
}

async function handleOpenAICallback(code, pkce, email, callbackState, client) {
  const authCode = await acquireAuthCode(code, callbackState);
  if (!authCode) return { type: "failed" };
  const cleanCode = authCode.split(/[&#?]/)[0];
  const params = new URLSearchParams({ grant_type: "authorization_code", code: cleanCode, redirect_uri: OPENAI_REDIRECT_URI, client_id: OPENAI_CLIENT_ID, code_verifier: pkce.verifier });
  const result = await fetchOpenAITokenEndpoint(params, "token exchange");
  if (!result.ok) return { type: "failed" };
  const json = await result.json();
  let resolvedEmail = email, accountId = "";
  if (json.access_token) {
    accountId = extractOpenAIAccountId(json.access_token);
    if (resolvedEmail === "unknown") resolvedEmail = resolveEmailFromJWTClaims(json.access_token) || "unknown";
    if (resolvedEmail === "unknown") { resolvedEmail = (await resolveEmailFromEndpoint(json.access_token, `${OPENAI_ISSUER}/userinfo`, { "User-Agent": OPENCODE_USER_AGENT })) || "unknown"; if (resolvedEmail !== "unknown") console.error(`[aidevops] OAuth pool: resolved OpenAI email ${resolvedEmail}`); }
  }
  return saveAccountAndInject({ provider: "openai", client, email: resolvedEmail, tokenData: { refresh: json.refresh_token || "", access: json.access_token, expires: Date.now() + (json.expires_in || 3600) * 1000 }, extras: { accountId }, envKey: "OPENAI_API_KEY", authId: "openai", injectFn: injectOpenAIPoolToken });
}

async function handleCursorAuthorize(email, client) {
  let creds = readCursorAuthJsonCredentials(email);
  if (creds) console.error("[aidevops] OAuth pool: found Cursor credentials in auth.json");
  if (!creds) { creds = readCursorStateDbCredentials(email); if (creds) console.error("[aidevops] OAuth pool: found Cursor credentials in state DB"); }
  if (!creds) {
    if (!isCursorAgentAvailable()) { console.error("[aidevops] OAuth pool: cursor-agent not found"); return { type: "failed" }; }
    console.error("[aidevops] OAuth pool: running cursor-agent login...");
    try { execSync("cursor-agent login", { encoding: "utf-8", timeout: 120_000, stdio: ["inherit", "pipe", "pipe"] }); creds = readCursorAuthJsonCredentials(email); }
    catch (err) { console.error(`[aidevops] OAuth pool: cursor-agent login failed: ${err.message}`); return { type: "failed" }; }
  }
  if (!creds) { console.error("[aidevops] OAuth pool: no Cursor access token obtained"); return { type: "failed" }; }
  const resolvedEmail = (email === "unknown" && creds.email) ? creds.email : email;
  const tokenInfo = decodeCursorJWT(creds.access);
  return saveAccountAndInject({ provider: "cursor", client, email: resolvedEmail, tokenData: { refresh: creds.refresh || "", access: creds.access, expires: tokenInfo.expiresAt || (Date.now() + 3600_000) }, injectFn: injectCursorPoolToken, successExtras: { key: "cursor-pool" } });
}

async function handleGoogleCallback(code, pkce, email, client) {
  const authCode = code?.trim();
  if (!authCode || authCode.length < 5) return { type: "failed" };
  const result = await fetchGoogleTokenEndpoint(JSON.stringify({ code: authCode, grant_type: "authorization_code", client_id: GOOGLE_CLIENT_ID, redirect_uri: GOOGLE_REDIRECT_URI, code_verifier: pkce.verifier }), "Google token exchange");
  if (!result.ok) return { type: "failed" };
  const json = await result.json();
  let resolvedEmail = email;
  if (json.id_token && resolvedEmail === "unknown") { resolvedEmail = resolveEmailFromJWTClaims(json.id_token) || "unknown"; if (resolvedEmail !== "unknown") console.error(`[aidevops] OAuth pool: resolved Google email ${resolvedEmail} from ID token`); }
  if (resolvedEmail === "unknown" && json.access_token) { resolvedEmail = (await resolveEmailFromEndpoint(json.access_token, "https://www.googleapis.com/oauth2/v3/userinfo")) || "unknown"; if (resolvedEmail !== "unknown") console.error(`[aidevops] OAuth pool: resolved Google email ${resolvedEmail}`); }
  return saveAccountAndInject({ provider: "google", client, email: resolvedEmail, tokenData: { refresh: json.refresh_token || "", access: json.access_token, expires: Date.now() + (json.expires_in || 3600) * 1000 }, envKey: "GOOGLE_OAUTH_ACCESS_TOKEN", injectFn: injectGooglePoolToken });
}

// ---------------------------------------------------------------------------
// Auth hooks (thin wrappers)
// ---------------------------------------------------------------------------

export function createPoolAuthHook(client) {
  return { provider: "anthropic-pool", methods: [{ get label() { const a = getAccounts("anthropic"); return a.length === 0 ? "Add Account to Pool (Claude Pro/Max)" : `Add Account to Pool (${a.length} account${a.length === 1 ? "" : "s"})`; }, type: "oauth", prompts: [makeEmailPrompt("anthropic")],
    authorize: async (inputs) => { const email = inputs?.email || "unknown"; const pkce = generatePKCE(); const url = new URL(ANTHROPIC_OAUTH_AUTHORIZE_URL); url.searchParams.set("code", "true"); url.searchParams.set("client_id", ANTHROPIC_CLIENT_ID); url.searchParams.set("response_type", "code"); url.searchParams.set("redirect_uri", ANTHROPIC_REDIRECT_URI); url.searchParams.set("scope", ANTHROPIC_OAUTH_SCOPES); url.searchParams.set("code_challenge", pkce.challenge); url.searchParams.set("code_challenge_method", "S256"); url.searchParams.set("state", pkce.verifier); return { url: url.toString(), instructions: `Adding account: ${email}\nPaste the authorization code here: `, method: "code", callback: (code) => handleAnthropicCallback(code, pkce, email, client) }; } }] };
}

export function createOpenAIPoolAuthHook(client) {
  return { provider: "openai-pool", methods: [{ get label() { const a = getAccounts("openai"); return a.length === 0 ? "Add Account to Pool (ChatGPT Plus/Pro)" : `Add Account to Pool (${a.length} account${a.length === 1 ? "" : "s"})`; }, type: "oauth", prompts: [makeEmailPrompt("openai")],
    authorize: async (inputs) => { const email = inputs?.email || "unknown"; const pkce = generatePKCE(); const cs = await initCallbackServerSafe(); const url = new URL(OPENAI_OAUTH_AUTHORIZE_URL); url.searchParams.set("client_id", OPENAI_CLIENT_ID); url.searchParams.set("response_type", "code"); url.searchParams.set("redirect_uri", OPENAI_REDIRECT_URI); url.searchParams.set("scope", OPENAI_OAUTH_SCOPES); url.searchParams.set("code_challenge", pkce.challenge); url.searchParams.set("code_challenge_method", "S256"); return { url: url.toString(), instructions: [`Adding OpenAI account: ${email}`, "1. A browser window will open to auth.openai.com", "2. Sign in with your ChatGPT Plus/Pro account", cs.ready ? "3. The code will be captured automatically" : "3. Copy the authorization code from the browser URL", cs.ready ? "4. Press Enter here to complete (or paste manually): " : "4. Paste the authorization code here: "].join("\n"), method: "code", callback: (code) => handleOpenAICallback(code, pkce, email, cs, client) }; } }] };
}

export function createCursorPoolAuthHook(client) {
  return { provider: "cursor-pool", methods: [{ get label() { const a = getAccounts("cursor"); return a.length === 0 ? "Add Account to Pool (Cursor Pro)" : `Add Account to Pool (${a.length} account${a.length === 1 ? "" : "s"})`; }, type: "api", prompts: [makeEmailPrompt("cursor")], authorize: (inputs) => handleCursorAuthorize(inputs?.email || "unknown", client) }] };
}

export function createGooglePoolAuthHook(client) {
  return { provider: "google-pool", methods: [{ get label() { const a = getAccounts("google"); return a.length === 0 ? "Add Account to Pool (Google AI Pro/Ultra/Workspace)" : `Add Account to Pool (${a.length} account${a.length === 1 ? "" : "s"})`; }, type: "oauth", prompts: [makeEmailPrompt("google", "you@gmail.com")],
    authorize: async (inputs) => { const email = inputs?.email || "unknown"; const pkce = generatePKCE(); const url = new URL(GOOGLE_OAUTH_AUTHORIZE_URL); url.searchParams.set("client_id", GOOGLE_CLIENT_ID); url.searchParams.set("response_type", "code"); url.searchParams.set("redirect_uri", GOOGLE_REDIRECT_URI); url.searchParams.set("scope", GOOGLE_OAUTH_SCOPES); url.searchParams.set("code_challenge", pkce.challenge); url.searchParams.set("code_challenge_method", "S256"); url.searchParams.set("access_type", "offline"); url.searchParams.set("prompt", "consent"); return { url: url.toString(), instructions: [`Adding Google AI account: ${email}`, "1. A browser window will open to accounts.google.com", "2. Sign in with your Google AI Pro/Ultra or Workspace account", "3. Copy the authorization code shown in the browser", "4. Paste the authorization code here: "].join("\n"), method: "code", callback: (code) => handleGoogleCallback(code, pkce, email, client) }; } }] };
}

// ---------------------------------------------------------------------------
// Provider registration
// ---------------------------------------------------------------------------

export function registerPoolProvider(config) {
  if (!config.provider) config.provider = {};
  let registered = 0;
  const defs = [
    { id: "anthropic-pool", name: "Anthropic Pool (Account Management)", npm: "@ai-sdk/anthropic", api: "https://api.anthropic.com/v1", mn: "[Account Setup Only] Use Anthropic provider for models" },
    { id: "openai-pool", name: "OpenAI Pool (Account Management)", npm: "@ai-sdk/openai", api: "https://api.openai.com/v1", mn: "[Account Setup Only] Use OpenAI provider for models" },
    { id: "cursor-pool", name: "Cursor Pool (Account Management)", npm: "@ai-sdk/openai-compatible", api: CURSOR_PROXY_BASE_URL, mn: "[Account Setup Only] Use Cursor provider for models" },
    { id: "google-pool", name: "Google Pool (Account Management)", npm: "@ai-sdk/google", api: "https://generativelanguage.googleapis.com/v1beta", mn: "[Account Setup Only] Token injected as GOOGLE_OAUTH_ACCESS_TOKEN" },
  ];
  for (const def of defs) {
    const models = { "pool-account-management": { name: def.mn, attachment: false, tool_call: false, temperature: false, modalities: { input: ["text"], output: ["text"] }, cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 }, limit: { context: 1000, output: 100 }, family: "pool" } };
    if (!config.provider[def.id]) { config.provider[def.id] = { name: def.name, npm: def.npm, api: def.api, models }; registered++; }
    else { const e = config.provider[def.id]; if (e.name !== def.name || e.npm !== def.npm || e.api !== def.api || JSON.stringify(e.models) !== JSON.stringify(models)) { Object.assign(e, { name: def.name, npm: def.npm, api: def.api, models }); registered++; } }
  }
  return registered;
}
