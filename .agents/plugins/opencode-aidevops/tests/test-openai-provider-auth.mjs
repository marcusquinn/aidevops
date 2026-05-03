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
      const { installOpenAIProviderFetchRotation } = await import("./openai-provider-auth.mjs?case=" + Math.random());
      installOpenAIProviderFetchRotation({ auth: { set: async (entry) => authWrites.push(entry) } });
      const response = await fetch(request.url, request.init);
      return { response, calls, authWrites, pool: JSON.parse(readFileSync(poolPath, "utf-8")) };
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
  `;
  execFileSync(process.execPath, ["--input-type=module", "--eval", script], {
    cwd: join(import.meta.dirname, ".."),
    env: { ...process.env, HOME: home },
    stdio: "pipe",
  });
});
