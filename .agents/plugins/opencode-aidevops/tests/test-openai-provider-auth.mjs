import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

function loadModule() {
  return import(`../openai-provider-auth.mjs?test=${Date.now()}-${Math.random()}`);
}

test("detects OpenAI provider requests only", async () => {
  const { isOpenAIProviderRequest } = await loadModule();
  assert.equal(isOpenAIProviderRequest("https://api.openai.com/v1/chat/completions"), true);
  assert.equal(isOpenAIProviderRequest("https://api.openai.com/dashboard"), false);
  assert.equal(isOpenAIProviderRequest("https://example.com/v1/chat/completions"), false);
});

test("detects OpenAI usage-limit responses", async () => {
  const { isOpenAIUsageLimitResponse } = await loadModule();
  const quota = new Response(JSON.stringify({ error: { code: "insufficient_quota", message: "Usage limit reached" } }), {
    status: 403,
    headers: { "content-type": "application/json" },
  });
  assert.equal(await isOpenAIUsageLimitResponse(quota), true);
  assert.equal(await isOpenAIUsageLimitResponse(new Response("ok", { status: 200 })), false);
});

test("detects OpenAI overloaded responses and stream chunks", async () => {
  const { isOpenAIOverloadResponse, isOpenAIOverloadText } = await loadModule();
  const overloaded = new Response(
    JSON.stringify({ error: { type: "service_unavailable_error", code: "server_is_overloaded" } }),
    { status: 503, headers: { "content-type": "application/json" } },
  );
  assert.equal(await isOpenAIOverloadResponse(overloaded), true);
  assert.equal(isOpenAIOverloadText('{"type":"error","error":{"code":"server_is_overloaded"}}'), true);
  assert.equal(await isOpenAIOverloadResponse(new Response("ok", { status: 200 })), false);
});

test("installed fetch guard rotates on response failures and pre-request cooldowns", async () => {
  const home = mkdtempSync(join(tmpdir(), "aidevops-openai-rotation-"));
  const script = String.raw`
    import assert from "node:assert/strict";
    import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
    import { join } from "node:path";

    const home = process.env.HOME;
    const aidevopsDir = join(home, ".aidevops");
    mkdirSync(aidevopsDir, { recursive: true });
    const poolPath = join(aidevopsDir, "oauth-pool.json");

    async function withInstalledGuard(pool, fetchImpl, request) {
      writeFileSync(poolPath, JSON.stringify(pool));
      const calls = [];
      globalThis.fetch = async (input, init) => fetchImpl(input, init, calls);
      const authWrites = [];
      const toasts = [];
      const { installOpenAIProviderFetchRotation } = await import("./openai-provider-auth.mjs?case=" + Math.random());
      installOpenAIProviderFetchRotation({
        auth: { set: async (entry) => authWrites.push(entry) },
        tui: { showToast: async (toast) => toasts.push(toast) },
      });
      const response = await fetch(request.url, request.init);
      return { response, calls, authWrites, toasts, pool: JSON.parse(readFileSync(poolPath, "utf-8")) };
    }

    const responseRotation = await withInstalledGuard({
      openai: [
        { email: "limited@example.com", access: "limited-token", refresh: "limited-refresh", expires: Date.now() + 3600_000, status: "active", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z" },
        { email: "healthy@example.com", access: "healthy-token", refresh: "healthy-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_healthy" },
      ],
    }, async (input, init, calls) => {
      calls.push(new Headers(init?.headers).get("authorization"));
      if (calls.length === 1) {
        return new Response(JSON.stringify({ error: { code: "insufficient_quota", message: "usage limit" } }), {
          status: 403,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response("ok", { status: 200 });
    }, {
      url: "https://api.openai.com/v1/chat/completions",
      init: { method: "POST", headers: { authorization: "Bearer limited-token" }, body: "{}" },
    });

    assert.equal(responseRotation.response.status, 200);
    assert.deepEqual(responseRotation.calls, ["Bearer limited-token", "Bearer healthy-token"]);
    assert.equal(responseRotation.pool.openai[0].status, "rate-limited");
    assert.equal(responseRotation.pool.openai[1].status, "active");
    assert.equal(responseRotation.authWrites[0].path.id, "openai");
    assert.equal(responseRotation.authWrites[0].body.accountId, "acct_healthy");

    const cooldownPreflight = await withInstalledGuard({
      openai: [
        { email: "cooldown@example.com", access: "cooldown-token", refresh: "cooldown-refresh", expires: Date.now() + 3600_000, status: "rate-limited", cooldownUntil: Date.now() + 4 * 86400_000, lastUsed: "2026-01-02T00:00:00Z" },
        { email: "fresh@example.com", access: "fresh-token", refresh: "fresh-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z" },
      ],
    }, async (input, init, calls) => {
      calls.push(new Headers(init?.headers).get("authorization"));
      return new Response("ok", { status: 200 });
    }, {
      url: "https://api.openai.com/v1/responses",
      init: { method: "POST", headers: { authorization: "Bearer cooldown-token" }, body: "{}" },
    });

    assert.equal(cooldownPreflight.response.status, 200);
    assert.deepEqual(cooldownPreflight.calls, ["Bearer fresh-token"]);

    const streamRetry = await withInstalledGuard({
      openai: [
        { email: "active@example.com", access: "active-token", refresh: "active-refresh", expires: Date.now() + 3600_000, status: "active", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z" },
      ],
    }, async (input, init, calls) => {
      calls.push(new Headers(init?.headers).get("authorization"));
      if (calls.length === 1) {
        return new Response('data: {"type":"error","sequence_number":2,"error":{"type":"service_unavailable_error","code":"server_is_overloaded","message":"Our servers are currently overloaded. Please try again later.","param":null}}\n\n', {
          status: 200,
          headers: { "content-type": "text/event-stream" },
        });
      }
      return new Response('data: {"type":"response.output_text.delta","delta":"ok"}\n\n', {
        status: 200,
        headers: { "content-type": "text/event-stream" },
      });
    }, {
      url: "https://api.openai.com/v1/responses",
      init: { method: "POST", headers: { authorization: "Bearer active-token" }, body: "{}" },
    });

    assert.equal(await streamRetry.response.text(), 'data: {"type":"response.output_text.delta","delta":"ok"}\n\n');
    assert.deepEqual(streamRetry.calls, ["Bearer active-token", "Bearer active-token"]);
    assert.match(streamRetry.toasts[0].body.message, /OpenAI overloaded\. Retrying in 0ms/);

    const missingBodyRetry = await withInstalledGuard({
      openai: [
        { email: "active@example.com", access: "active-token", refresh: "active-refresh", expires: Date.now() + 3600_000, status: "active", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z" },
      ],
    }, async (input, init, calls) => {
      calls.push(new Headers(init?.headers).get("authorization"));
      if (calls.length === 1) {
        return new Response('data: {"type":"error","error":{"type":"service_unavailable_error","code":"server_is_overloaded"}}\n\n', {
          status: 200,
          headers: { "content-type": "text/event-stream" },
        });
      }
      return new Response(null, {
        status: 204,
        headers: { "content-type": "text/event-stream" },
      });
    }, {
      url: "https://api.openai.com/v1/responses",
      init: { method: "POST", headers: { authorization: "Bearer active-token" }, body: "{}" },
    });

    await assert.rejects(() => missingBodyRetry.response.text(), /retry response missing body \(status: 204\)/);
    assert.deepEqual(missingBodyRetry.calls, ["Bearer active-token", "Bearer active-token"]);
  `;
  execFileSync(process.execPath, ["--input-type=module", "--eval", script], {
    cwd: join(import.meta.dirname, ".."),
    env: { ...process.env, HOME: home, AIDEVOPS_OPENAI_OVERLOAD_RETRY_DELAYS_MS: "0,0" },
    stdio: "pipe",
  });
});

test("OpenAI startup injection honors current auth availability", async () => {
  const home = mkdtempSync(join(tmpdir(), "aidevops-openai-startup-"));
  const script = String.raw`
    import assert from "node:assert/strict";
    import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
    import { join } from "node:path";

    const home = process.env.HOME;
    const aidevopsDir = join(home, ".aidevops");
    const opencodeDir = join(home, ".local", "share", "opencode");
    mkdirSync(aidevopsDir, { recursive: true });
    mkdirSync(opencodeDir, { recursive: true });
    const poolPath = join(aidevopsDir, "oauth-pool.json");
    const authPath = join(opencodeDir, "auth.json");

    async function injectWithPool(pool, auth, skipEmail) {
      writeFileSync(poolPath, JSON.stringify(pool));
      writeFileSync(authPath, JSON.stringify({ openai: auth }));
      const authWrites = [];
      const { injectOpenAIPoolToken } = await import("./oauth-pool.mjs?case=" + Math.random());
      const ok = await injectOpenAIPoolToken({ auth: { set: async (entry) => authWrites.push(entry) } }, skipEmail);
      return { ok, authWrites, pool: JSON.parse(readFileSync(poolPath, "utf-8")) };
    }

    const preserved = await injectWithPool({ openai: [
      { email: "old@example.com", access: "old-token", refresh: "old-refresh", expires: Date.now() + 3600_000, status: "active", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_old" },
      { email: "current@example.com", access: "current-token", refresh: "current-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z", accountId: "acct_current" },
    ] }, { type: "oauth", access: "current-token", refresh: "current-refresh", expires: Date.now() + 3600_000, accountId: "acct_current" });

    assert.equal(preserved.ok, true);
    assert.equal(preserved.authWrites[0].body.accountId, "acct_current");
    assert.equal(preserved.pool.openai[1].status, "active");

    const rotated = await injectWithPool({ openai: [
      { email: "cooldown@example.com", access: "cooldown-token", refresh: "cooldown-refresh", expires: Date.now() + 3600_000, status: "rate-limited", cooldownUntil: Date.now() + 86400_000, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_cooldown" },
      { email: "fresh@example.com", access: "fresh-token", refresh: "fresh-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z", accountId: "acct_fresh" },
    ] }, { type: "oauth", access: "cooldown-token", refresh: "cooldown-refresh", expires: Date.now() + 3600_000, accountId: "acct_cooldown" });

    assert.equal(rotated.ok, true);
    assert.equal(rotated.authWrites[0].body.accountId, "acct_fresh");

    const authErrorRotated = await injectWithPool({ openai: [
      { email: "auth-error@example.com", access: "auth-error-token", refresh: "auth-error-refresh", expires: Date.now() + 3600_000, status: "auth-error", cooldownUntil: Date.now() + 86400_000, lastUsed: "2026-01-03T00:00:00Z", accountId: "acct_auth_error" },
      { email: "fallback@example.com", access: "fallback-token", refresh: "fallback-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_fallback" },
    ] }, { type: "oauth", access: "auth-error-token", refresh: "auth-error-refresh", expires: Date.now() + 3600_000, accountId: "acct_auth_error" });

    assert.equal(authErrorRotated.ok, true);
    assert.equal(authErrorRotated.authWrites[0].body.accountId, "acct_fallback");

    const skippedAccountAvoided = await injectWithPool({ openai: [
      { email: "current@example.com", access: "current-token", refresh: "current-refresh", expires: Date.now() + 3600_000, status: "rate-limited", cooldownUntil: Date.now() + 86400_000, lastUsed: "2026-01-03T00:00:00Z", accountId: "acct_current" },
      { email: "skip@example.com", access: "skip-token", refresh: "skip-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_skip" },
      { email: "fallback@example.com", access: "fallback-token", refresh: "fallback-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z", accountId: "acct_fallback" },
    ] }, { type: "oauth", access: "current-token", refresh: "current-refresh", expires: Date.now() + 3600_000, accountId: "acct_current" }, "skip@example.com");

    assert.equal(skippedAccountAvoided.ok, true);
    assert.equal(skippedAccountAvoided.authWrites[0].body.accountId, "acct_fallback");
  `;
  execFileSync(process.execPath, ["--input-type=module", "--eval", script], {
    cwd: join(import.meta.dirname, ".."),
    env: { ...process.env, HOME: home, XDG_DATA_HOME: join(home, ".local", "share") },
    stdio: "pipe",
  });
});
