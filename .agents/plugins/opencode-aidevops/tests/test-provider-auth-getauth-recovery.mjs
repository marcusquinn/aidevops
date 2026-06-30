import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

test("provider auth recovers when getAuth throws Token refresh failed: 401", async () => {
  const home = mkdtempSync(join(tmpdir(), "aidevops-provider-auth-401-"));
  const aidevopsDir = join(home, ".aidevops");
  mkdirSync(aidevopsDir, { recursive: true });
  writeFileSync(join(aidevopsDir, "oauth-pool.json"), JSON.stringify({
    anthropic: [{
      email: "pool@example.com",
      access: "valid-pool-access",
      refresh: "valid-pool-refresh",
      expires: Date.now() + 3600_000,
      status: "idle",
      cooldownUntil: 0,
      lastUsed: "2026-01-01T00:00:00.000Z",
    }],
  }));

  const previousHome = process.env.HOME;
  const previousFetch = globalThis.fetch;
  process.env.HOME = home;
  const authSetCalls = [];
  globalThis.fetch = async (_input, init) => {
    assert.equal(init.headers.get("authorization"), "Bearer valid-pool-access");
    return new Response("ok", { status: 200 });
  };

  try {
    const { createProviderAuthHook } = await import(`../provider-auth.mjs?case=${Date.now()}-${Math.random()}`);
    const hook = createProviderAuthHook({
      auth: {
        async set(payload) { authSetCalls.push(payload); },
      },
    });
    const provider = { models: { test: {} } };
    const auth = await hook.loader(async () => {
      throw new Error("Token refresh failed: 401");
    }, provider);

    const response = await auth.fetch("http://127.0.0.1/v1/messages", { method: "POST", body: "{}" });

    assert.equal(response.status, 200);
    assert.equal(authSetCalls.length, 1);
    assert.equal(authSetCalls[0].body.access, "valid-pool-access");
  } finally {
    process.env.HOME = previousHome;
    globalThis.fetch = previousFetch;
  }
});
