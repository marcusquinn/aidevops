import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

function loadModule() {
  return import(`../oauth-pool-refresh.mjs?test=${Date.now()}-${Math.random()}`);
}

test("OAuth refresh auth failures use exponential backoff capped at 10 minutes", async () => {
  const { authFailureBackoffMs } = await loadModule();

  assert.equal(authFailureBackoffMs(1), 60_000);
  assert.equal(authFailureBackoffMs(2), 120_000);
  assert.equal(authFailureBackoffMs(3), 240_000);
  assert.equal(authFailureBackoffMs(4), 480_000);
  assert.equal(authFailureBackoffMs(5), 600_000);
  assert.equal(authFailureBackoffMs(10), 600_000);
});

test("markAuthRefreshFailure persists retry state in the pool", () => {
  const home = mkdtempSync(join(tmpdir(), "aidevops-oauth-backoff-"));
  const script = String.raw`
    import assert from "node:assert/strict";
    import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
    import { join } from "node:path";

    const home = process.env.HOME;
    const aidevopsDir = join(home, ".aidevops");
    mkdirSync(aidevopsDir, { recursive: true });
    const poolPath = join(aidevopsDir, "oauth-pool.json");
    writeFileSync(poolPath, JSON.stringify({ anthropic: [{
      email: "a@example.com",
      access: "old-access",
      refresh: "old-refresh",
      expires: 1,
      status: "idle",
      cooldownUntil: 0,
      authRefreshFailures: 1,
    }] }));

    const account = JSON.parse(readFileSync(poolPath, "utf-8")).anthropic[0];
    const before = Date.now();
    const { markAuthRefreshFailure } = await import("./oauth-pool-refresh.mjs?case=" + Math.random());
    const cooldownMs = markAuthRefreshFailure("anthropic", account);
    const after = Date.now();
    const saved = JSON.parse(readFileSync(poolPath, "utf-8")).anthropic[0];

    assert.equal(cooldownMs, 120000);
    assert.equal(saved.status, "auth-error");
    assert.equal(saved.authRefreshFailures, 2);
    assert.ok(saved.authRefreshLastFailureAt >= before && saved.authRefreshLastFailureAt <= after);
    assert.ok(saved.cooldownUntil >= before + 120000 && saved.cooldownUntil <= after + 120000);
  `;

  execFileSync(process.execPath, ["--input-type=module", "--eval", script], {
    cwd: join(import.meta.dirname, ".."),
    env: { ...process.env, HOME: home },
    stdio: "pipe",
  });
});
