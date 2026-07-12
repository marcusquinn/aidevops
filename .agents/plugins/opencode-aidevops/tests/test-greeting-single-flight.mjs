// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
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

function runNode(script) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [script], (error) => error ? reject(error) : resolve());
  });
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

test("headless sessions never emit or refresh a greeting", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  writeFileSync(f.cacheFile, `${OLD_GREETING}\n`);
  let spawnCount = 0;
  const handler = createGreetingHandler({
    ...handlerOptions(f, f.client(), async () => {
      spawnCount += 1;
      return { stdout: NEW_GREETING };
    }),
    isHeadless: () => true,
  });

  await handler({ event: { type: "session.created" } });

  assert.equal(spawnCount, 0);
  assert.equal(f.clients[0].length, 0);
});

test("subagent session events do not consume or emit the root greeting", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  writeFileSync(f.cacheFile, `${OLD_GREETING}\n`);
  const handler = createGreetingHandler(handlerOptions(f, f.client(), async () => ({ stdout: NEW_GREETING })));

  await handler({ event: { type: "session.created", properties: { info: { id: "child", parentID: "root" } } } });
  await handler({ event: { type: "session.created", properties: { info: { id: "root" } } } });

  assert.equal(f.clients[0].length, 1);
  assert.match(f.clients[0][0].message, /aidevops v1\.0\.0/);
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

test("cold-cache plugin processes share one refresh and all receive its greeting", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  const workerFile = join(f.cacheDir, "worker.mjs");
  const spawnFile = join(f.cacheDir, "spawns");
  const toastFile = join(f.cacheDir, "toasts");
  const greetingUrl = new URL("../greeting.mjs", import.meta.url).href;
  writeFileSync(workerFile, `
    import { appendFileSync } from "node:fs";
    import { createGreetingHandler } from ${JSON.stringify(greetingUrl)};
    const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const handler = createGreetingHandler({
      scriptsDir: "/unused",
      cacheDir: ${JSON.stringify(f.cacheDir)},
      lockStaleMs: 1000,
      client: { tui: { showToast: async () => appendFileSync(${JSON.stringify(toastFile)}, "1\\n") } },
      execGreeting: async () => {
        appendFileSync(${JSON.stringify(spawnFile)}, "1\\n");
        await delay(75);
        return { stdout: ${JSON.stringify(NEW_GREETING)} };
      },
      maintenanceNoticeFn: async () => "",
    });
    await handler({ event: { type: "session.created" } });
    await delay(250);
  `);

  await Promise.all(Array.from({ length: 8 }, () => runNode(workerFile)));

  assert.equal(readFileSync(spawnFile, "utf8").trim().split("\n").length, 1);
  assert.equal(readFileSync(toastFile, "utf8").trim().split("\n").length, 8);
  assert.equal(readFileSync(f.cacheFile, "utf8").trim(), NEW_GREETING);
});

test("cold-cache follower emits a cache published while its owner lock disappears", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  const lockDir = join(f.cacheDir, "session-greeting-refresh.lock");
  mkdirSync(lockDir);
  let nowCalls = 0;
  const now = () => {
    nowCalls += 1;
    if (nowCalls === 5) {
      writeFileSync(f.cacheFile, `${NEW_GREETING}\n`);
      rmSync(lockDir, { recursive: true, force: true });
    }
    return 1000;
  };
  const client = f.client();
  const handler = createGreetingHandler({
    ...handlerOptions(f, client, async () => {
      throw new Error("follower must not start a refresh");
    }),
    now,
  });

  await handler({ event: { type: "session.created" } });
  await waitFor(() => f.clients[0].length === 1);

  assert.equal(nowCalls, 5);
  assert.equal(f.clients[0][0].message.includes(NEW_GREETING), true);
});

test("cold-cache follower survives a transient lock gap before publication", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  const lockDir = join(f.cacheDir, "session-greeting-refresh.lock");
  mkdirSync(lockDir);
  let nowCalls = 0;
  const now = () => {
    nowCalls += 1;
    if (nowCalls === 5) rmSync(lockDir, { recursive: true, force: true });
    if (nowCalls === 6) mkdirSync(lockDir);
    return 1000;
  };
  const handler = createGreetingHandler({
    ...handlerOptions(f, f.client(), async () => {
      throw new Error("follower must not start a refresh");
    }),
    now,
  });

  await handler({ event: { type: "session.created" } });
  assert.equal(nowCalls, 6);
  writeFileSync(f.cacheFile, `${NEW_GREETING}\n`);
  rmSync(lockDir, { recursive: true, force: true });
  await waitFor(() => f.clients[0].length === 1);

  assert.equal(f.clients[0][0].message.includes(NEW_GREETING), true);
});

test("an expired owner cannot release a replacement owner's lock", async (t) => {
  const f = fixture();
  t.after(() => f.cleanup());
  const lockDir = join(f.cacheDir, "session-greeting-refresh.lock");
  let resolveFirst;
  let resolveSecond;
  const firstRefresh = new Promise((resolve) => { resolveFirst = resolve; });
  const secondRefresh = new Promise((resolve) => { resolveSecond = resolve; });
  const first = createGreetingHandler({
    ...handlerOptions(f, f.client(), () => firstRefresh),
    lockStaleMs: 1,
  });
  await first({ event: { type: "session.created" } });
  await waitFor(() => readdirSync(f.cacheDir).includes("session-greeting-refresh.lock"));
  utimesSync(lockDir, new Date(0), new Date(0));

  const second = createGreetingHandler({
    ...handlerOptions(f, f.client(), () => secondRefresh),
    lockStaleMs: 1,
  });
  await second({ event: { type: "session.created" } });
  resolveFirst({ stdout: OLD_GREETING });
  await waitFor(() => cacheEquals(f, OLD_GREETING));
  assert.ok(readdirSync(f.cacheDir).includes("session-greeting-refresh.lock"));

  resolveSecond({ stdout: NEW_GREETING });
  await waitFor(() => cacheEquals(f, NEW_GREETING));
  await waitFor(() => !readdirSync(f.cacheDir).includes("session-greeting-refresh.lock"));
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
