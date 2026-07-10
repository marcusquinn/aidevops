// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createGreetingHandler } from "../greeting.mjs";

const OLD_GREETING = "aidevops v1.0.0 running in OpenCode v1.0.0";
const NEW_GREETING = "aidevops v1.0.1 running in OpenCode v1.0.1";

function fixture() {
  const cacheDir = mkdtempSync(join(tmpdir(), "aidevops-greeting-test-"));
  const cacheFile = join(cacheDir, "session-greeting.txt");
  const clients = [];
  return {
    cacheDir,
    cacheFile,
    clients,
    client() {
      const toasts = [];
      clients.push(toasts);
      return { tui: { showToast: async ({ body }) => toasts.push(body) } };
    },
    cleanup() {
      rmSync(cacheDir, { recursive: true, force: true });
    },
  };
}

async function waitFor(predicate, timeoutMs = 1000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("timed out waiting for greeting refresh");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function cacheEquals(f, expected) {
  try {
    return readFileSync(f.cacheFile, "utf8").trim() === expected;
  } catch {
    return false;
  }
}

function handlerOptions(f, client, execGreeting) {
  return {
    scriptsDir: "/unused",
    client,
    cacheDir: f.cacheDir,
    refreshTtlMs: 1000,
    lockStaleMs: 2000,
    execGreeting,
    maintenanceNoticeFn: async () => "",
  };
}

test("eight concurrent plugin handlers share one stale-cache refresh", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  writeFileSync(f.cacheFile, `${OLD_GREETING}\n`);
  utimesSync(f.cacheFile, new Date(0), new Date(0));

  let resolveRefresh;
  let spawnCount = 0;
  const refresh = new Promise((resolve) => { resolveRefresh = resolve; });
  const execGreeting = () => {
    spawnCount += 1;
    return refresh;
  };
  const handlers = Array.from({ length: 8 }, () =>
    createGreetingHandler(handlerOptions(f, f.client(), execGreeting)));

  await Promise.all(handlers.map((handler) => handler({ event: { type: "session.created" } })));

  assert.equal(spawnCount, 1);
  assert.ok(f.clients.every((toasts) => toasts.length === 1));
  assert.ok(f.clients.every((toasts) => toasts[0].message.includes(OLD_GREETING)));

  resolveRefresh({ stdout: NEW_GREETING });
  await waitFor(() => cacheEquals(f, NEW_GREETING));
});

test("fresh cache emits immediately without spawning a refresh", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  writeFileSync(f.cacheFile, `${OLD_GREETING}\n`);
  let spawnCount = 0;
  const handler = createGreetingHandler(handlerOptions(f, f.client(), async () => {
    spawnCount += 1;
    return { stdout: NEW_GREETING };
  }));

  await handler({ event: { type: "session.created" } });

  assert.equal(spawnCount, 0);
  assert.equal(f.clients[0].length, 1);
});

test("stale lock is recovered within the configured bound", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  const lockDir = join(f.cacheDir, "session-greeting-refresh.lock");
  mkdirSync(lockDir);
  utimesSync(lockDir, new Date(0), new Date(0));
  let spawnCount = 0;
  const handler = createGreetingHandler({
    ...handlerOptions(f, f.client(), async () => {
      spawnCount += 1;
      return { stdout: NEW_GREETING };
    }),
    lockStaleMs: 1,
  });

  await handler({ event: { type: "session.created" } });
  await waitFor(() => spawnCount === 1 && cacheEquals(f, NEW_GREETING));
});

test("failed refresh preserves the last valid cache and releases its lock", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  writeFileSync(f.cacheFile, `${OLD_GREETING}\n`);
  utimesSync(f.cacheFile, new Date(0), new Date(0));
  const handler = createGreetingHandler(handlerOptions(f, f.client(), async () => {
    throw new Error("simulated failure");
  }));

  await handler({ event: { type: "session.created" } });
  await waitFor(() => !readdirSync(f.cacheDir).includes("session-greeting-refresh.lock"));

  assert.equal(readFileSync(f.cacheFile, "utf8").trim(), OLD_GREETING);
});

test("successful refresh atomically replaces the cache without temp files", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  const handler = createGreetingHandler(handlerOptions(f, f.client(), async () => ({ stdout: NEW_GREETING })));

  await handler({ event: { type: "session.created" } });
  await waitFor(() => readdirSync(f.cacheDir).includes("session-greeting.txt"));

  assert.equal(readFileSync(f.cacheFile, "utf8").trim(), NEW_GREETING);
  assert.deepEqual(readdirSync(f.cacheDir), ["session-greeting.txt"]);
});
