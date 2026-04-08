/**
 * OAuth Pool — MCP Tool (extracted from oauth-pool.mjs for complexity reduction)
 *
 * Contains: createPoolTool, all poolAction handlers, display formatting.
 *
 * @module oauth-pool-tool
 */

import {
  getAccounts, getPendingToken, removeAccount, assignPendingToken,
  resolveInjectFn, getEndpointCooldownValue, resetEndpointCooldown,
  getPoolFilePath, withPoolLock, loadPool, savePool,
  ANTHROPIC_USER_AGENT, OPENCODE_USER_AGENT, GOOGLE_HEALTH_CHECK_URL,
} from "./oauth-pool.mjs";

// ---------------------------------------------------------------------------
// Display formatting helpers
// ---------------------------------------------------------------------------

function formatDuration(ms) {
  const mins = Math.floor(ms / 60000);
  const hours = Math.floor(mins / 60);
  return hours > 0 ? `${hours}h ${mins % 60}m` : `${mins}m`;
}

function formatAgo(ms) {
  const mins = Math.floor(ms / 60000);
  const hours = Math.floor(mins / 60);
  return hours > 0 ? `${hours}h ${mins % 60}m ago` : `${mins}m ago`;
}

function interpretValidityStatus(status, okOn403, on403msg) {
  if (status === 401) return "INVALID (401 — needs refresh)";
  if (status === 403 && okOn403) return on403msg || "OK";
  if (status >= 200 && status < 300) return "OK";
  return `HTTP ${status}`;
}

async function checkAccountTokenValidity(prov, account) {
  try {
    if (prov === "anthropic") {
      const r = await fetch("https://api.anthropic.com/v1/models", { method: "GET", headers: { "Authorization": `Bearer ${account.access}`, "User-Agent": ANTHROPIC_USER_AGENT, "anthropic-version": "2023-06-01", "anthropic-beta": "oauth-2025-04-20" } });
      return interpretValidityStatus(r.status, true);
    }
    if (prov === "openai") {
      const r = await fetch("https://api.openai.com/v1/models", { headers: { "Authorization": `Bearer ${account.access}`, "User-Agent": OPENCODE_USER_AGENT } });
      return interpretValidityStatus(r.status, false);
    }
    if (prov === "google") {
      const r = await fetch(GOOGLE_HEALTH_CHECK_URL, { headers: { "Authorization": `Bearer ${account.access}` } });
      return interpretValidityStatus(r.status, true, "OK (403 — token valid, check AI Pro/Ultra subscription)");
    }
    return `(skipped — ${prov} uses proxy)`;
  } catch (err) { return `ERROR (${err.code || err.message})`; }
}

async function formatAccountCheckLines(prov, account, now) {
  const lines = [`  ${account.email}:`];
  const expiresIn = account.expires - now;
  lines.push(expiresIn <= 0 ? `    Token: EXPIRED (${new Date(account.expires).toLocaleString()})` : `    Token: expires in ${formatDuration(expiresIn)}`);
  lines.push(`    Status: ${account.status}`);
  if (account.cooldownUntil && account.cooldownUntil > now) lines.push(`    Cooldown: ${Math.ceil((account.cooldownUntil - now) / 60000)}m remaining`);
  if (account.lastUsed) lines.push(`    Last used: ${formatAgo(now - new Date(account.lastUsed).getTime())}`);
  lines.push(`    Refresh token: ${account.refresh ? "present" : "MISSING"}`);
  if (account.access && expiresIn > 0) lines.push(`    Validity: ${await checkAccountTokenValidity(prov, account)}`);
  else if (expiresIn <= 0) lines.push(`    Validity: EXPIRED — will auto-refresh on next use`);
  else lines.push(`    Validity: no access token`);
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Pool tool action handlers
// ---------------------------------------------------------------------------

function poolActionList(provider, accounts, hint, now) {
  if (accounts.length === 0) return `No accounts in the ${provider} pool.\n\n${hint}`;
  const lines = accounts.map((a, i) => {
    const cd = (a.cooldownUntil && a.cooldownUntil > now) ? ` (cooldown: ${Math.ceil((a.cooldownUntil - now) / 60000)}m remaining)` : "";
    const lu = a.lastUsed ? ` | last used: ${new Date(a.lastUsed).toLocaleString()}` : "";
    const aid = a.accountId ? ` | id: ${a.accountId.slice(0, 8)}...` : "";
    const pri = a.priority ? ` | priority: ${a.priority}` : "";
    return `${i + 1}. ${a.email} [${a.status}]${cd}${lu}${aid}${pri}`;
  });
  const pending = getPendingToken(provider);
  const pl = pending ? `\n\nPENDING: Unassigned token (added: ${pending.added}). Use assign-pending <email> to assign it.` : "";
  return `${provider} pool (${accounts.length} account${accounts.length === 1 ? "" : "s"}):\n\n${lines.join("\n")}${pl}`;
}

function poolActionRemove(provider, email) {
  if (!email) return "Error: email is required for remove action. Usage: remove <email>";
  if (!removeAccount(provider, email)) return `Account ${email} not found in ${provider} pool.`;
  const remaining = getAccounts(provider).length;
  return `Removed ${email} from ${provider} pool (${remaining} account${remaining === 1 ? "" : "s"} remaining).`;
}

function poolActionStatus(provider, accounts, hint, now) {
  if (accounts.length === 0) return `No accounts in the ${provider} pool.\n\n${hint}`;
  const active = accounts.filter((a) => ["active", "idle"].includes(a.status)).length;
  const rl = accounts.filter((a) => a.status === "rate-limited" && a.cooldownUntil && a.cooldownUntil > now).length;
  const ae = accounts.filter((a) => a.status === "auth-error").length;
  const avail = accounts.filter((a) => !a.cooldownUntil || a.cooldownUntil <= now).length;
  const epCd = getEndpointCooldownValue(provider);
  return [`${provider} pool status:`, `  Total accounts: ${accounts.length}`, `  Available now:  ${avail}`, `  Active/idle:    ${active}`, `  Rate limited:   ${rl}`, `  Auth errors:    ${ae}`, "",
    epCd > now ? `  TOKEN ENDPOINT: RATE LIMITED (${Math.ceil((epCd - now) / 60000)}m remaining)` : `  Token endpoint: OK`, `Pool file: ${getPoolFilePath()}`].join("\n");
}

function poolActionResetCooldowns(provider) {
  const wasGated = resetEndpointCooldown(provider);
  const resetCount = withPoolLock(() => {
    const pool = loadPool();
    let count = 0;
    if (pool[provider]) { for (const a of pool[provider]) { if (a.cooldownUntil) { a.cooldownUntil = null; a.status = "idle"; count++; } } savePool(pool); }
    return count;
  });
  const parts = [];
  if (wasGated) parts.push("token endpoint cooldown cleared");
  if (resetCount > 0) parts.push(`${resetCount} account cooldown${resetCount === 1 ? "" : "s"} cleared`);
  if (parts.length === 0) parts.push("no active cooldowns");
  return `Reset (${provider}): ${parts.join(", ")}. Token endpoint requests will proceed on next attempt.`;
}

async function poolActionRotate(client, provider, accounts) {
  if (accounts.length < 2) { const pn = { anthropic: "Anthropic Pool", openai: "OpenAI Pool", cursor: "Cursor Pool", google: "Google Pool" }; return `Cannot rotate: only ${accounts.length} account(s). Add more via Ctrl+A → ${pn[provider] || "Pool"}.`; }
  const current = [...accounts].sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0];
  if (!(await resolveInjectFn(provider)(client, current?.email))) return `Rotation failed (${provider}) — no other active accounts available.`;
  const newest = [...getAccounts(provider)].sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0];
  return `Rotated (${provider}): now using ${newest?.email || "unknown"}. Previous: ${current?.email || "unknown"}.`;
}

function poolActionAssignPending(provider, accounts, email) {
  const pending = getPendingToken(provider);
  if (!pending) return `No pending token for ${provider}.`;
  if (!email) return `Pending ${provider} token found (added: ${pending.added}). Assign to: ${accounts.map((a) => a.email).join(", ")}\n\nUsage: assign-pending with email parameter.`;
  return assignPendingToken(provider, email) ? `Assigned pending token to ${email} in ${provider} pool.` : `Failed: account ${email} not found. Available: ${accounts.map((a) => a.email).join(", ")}`;
}

function poolActionSetPriority(provider, email, priority) {
  if (!email) return "Error: email is required for set-priority action.";
  if (priority === undefined || priority === null) return "Error: priority (integer) is required.";
  const p = Number(priority);
  if (!Number.isInteger(p)) return `Error: priority must be an integer, got: ${priority}`;
  return withPoolLock(() => {
    const pool = loadPool();
    const accts = pool[provider] || [];
    const idx = accts.findIndex((a) => a.email === email);
    if (idx < 0) return `Account ${email} not found in ${provider} pool.`;
    if (p === 0) delete accts[idx].priority; else accts[idx].priority = p;
    savePool(pool);
    return p === 0 ? `Cleared priority for ${email} (defaults to LRU order).` : `Set priority ${p} for ${email}. Higher-priority accounts preferred during rotation.`;
  });
}

async function poolActionCheck(providerArg, now) {
  const provs = providerArg ? [providerArg] : ["anthropic", "openai", "cursor", "google"];
  const results = [];
  for (const prov of provs) {
    const accts = getAccounts(prov);
    if (accts.length === 0) continue;
    results.push(`\n## ${prov} (${accts.length} account${accts.length === 1 ? "" : "s"})`);
    for (const a of accts) results.push(await formatAccountCheckLines(prov, a, now));
    const epCd = getEndpointCooldownValue(prov);
    results.push(epCd > now ? `  Token endpoint: RATE LIMITED (${Math.ceil((epCd - now) / 60000)}m remaining)` : `  Token endpoint: OK`);
    const pending = getPendingToken(prov);
    if (pending) results.push(`  PENDING: Unassigned token (added: ${pending.added})`);
  }
  return results.length === 0 ? `No accounts in any pool.\n\nTo add: run \`opencode auth login\` (Ctrl+A), select a pool provider, enter email, complete OAuth, then switch to the main provider.` : `OAuth Pool Health Check${results.join("\n")}`;
}

// ---------------------------------------------------------------------------
// Tool definition
// ---------------------------------------------------------------------------

export function createPoolTool(client) {
  return {
    description: "Manage OAuth account pool for provider credential rotation. Actions: list, rotate, remove, assign-pending, check, status, reset-cooldowns, set-priority. Providers: anthropic, openai, cursor, google. Shell equivalent: oauth-pool-helper.sh.",
    parameters: { type: "object", properties: {
      action: { type: "string", enum: ["list", "remove", "status", "reset-cooldowns", "rotate", "assign-pending", "check", "set-priority"], description: "Action to perform" },
      email: { type: "string", description: "Account email (for remove/assign-pending/set-priority)" },
      provider: { type: "string", enum: ["anthropic", "openai", "cursor", "google"], description: "Provider (default: anthropic)" },
      priority: { type: "integer", description: "Rotation priority for set-priority (higher = preferred; 0 = LRU)" },
    }, required: ["action"] },
    async execute(args) {
      const provider = args.provider || "anthropic";
      const accounts = getAccounts(provider);
      const now = Date.now();
      const hints = { anthropic: 'run `opencode auth login` → "Anthropic Pool"', openai: 'run `opencode auth login` → "OpenAI Pool"', cursor: 'run `opencode auth login` → "Cursor Pool"', google: 'run `opencode auth login` → "Google Pool"' };
      const hint = `To add an account: ${hints[provider] || hints.anthropic}.`;
      const actions = {
        "list": () => poolActionList(provider, accounts, hint, now),
        "remove": () => poolActionRemove(provider, args.email),
        "status": () => poolActionStatus(provider, accounts, hint, now),
        "reset-cooldowns": () => poolActionResetCooldowns(provider),
        "rotate": () => poolActionRotate(client, provider, accounts),
        "assign-pending": () => poolActionAssignPending(provider, accounts, args.email),
        "check": () => poolActionCheck(args.provider, now),
        "set-priority": () => poolActionSetPriority(provider, args.email, args.priority),
      };
      const handler = actions[args.action];
      return handler ? handler() : `Unknown action: ${args.action}. Available: ${Object.keys(actions).join(", ")}`;
    },
  };
}
