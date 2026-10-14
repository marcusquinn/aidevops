// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  createPrivateRuntime,
  privateRuntimeParent,
  probeAuthenticatedRelay,
  reconcileStaleRelays,
  validatePlaywriterCommand,
  withTelemetryOptOut,
} from "../playwriter-authenticated-relay.mjs";
import {
  cleanupPrivateRuntime,
  processGroupAlive,
  terminateProcessGroup,
} from "../playwriter-relay-lifecycle.mjs";

const POSIX = process.platform !== "win32";
const GUARDIAN_ARGS = ["--aidevops-relay-guardian", "npx", "-y", "playwriter@0.8.0"];

// A package-runner stand-in: the group leader starts a loopback listener on an
// OS-assigned port that ignores SIGTERM, like a relay that outlives `npm exec`.
const DESCENDANT = "process.on('SIGTERM', () => {}); require('node:http').createServer().listen(0, '127.0.0.1', () => process.stdout.write('ready\\n')); setInterval(() => {}, 1000);";
const LEADER = `const { spawn } = require('node:child_process'); const child = spawn(process.execPath, ['-e', ${JSON.stringify(DESCENDANT)}], { stdio: ['ignore', 'pipe', 'ignore'] }); child.stdout.once('data', () => process.stdout.write(child.pid + '\\n')); setInterval(() => {}, 1000);`;

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function startSyntheticGroup(t, extraArgs = []) {
  // `--` keeps the guardian-shaped arguments out of Node's own option parser
  // while leaving them visible in the process command line.
  const leader = spawn(process.execPath, ["-e", LEADER, "--", ...extraArgs], {
    detached: true,
    stdio: ["ignore", "pipe", "ignore"],
  });
  t.after(() => {
    try { process.kill(-leader.pid, "SIGKILL"); } catch {}
  });
  const descendantPid = await new Promise((resolvePromise, rejectPromise) => {
    leader.stdout.once("data", (data) => resolvePromise(Number(String(data).trim())));
    leader.once("exit", (code) => rejectPromise(new Error(`synthetic group exited early: ${code}`)));
  });
  return { groupId: leader.pid, descendantPid };
}

function deadPid() {
  return spawnSync(process.execPath, ["-e", ""]).pid;
}

function writeSession(parent, supervisorPid, state) {
  const name = `session-${supervisorPid}-${randomUUID()}`;
  const directory = join(parent, name);
  mkdirSync(directory, { mode: 0o700 });
  writeFileSync(join(directory, ".aidevops-owned-relay"), "owner", { mode: 0o600 });
  writeFileSync(join(directory, "state.json"), `${JSON.stringify({
    schema: "aidevops-playwriter-relay/v2",
    host: "127.0.0.1",
    port: 19988,
    version: "0.8.0",
    supervisorPid,
    owned: true,
    ...state,
  })}\n`, { mode: 0o600 });
  return { name, directory };
}

test("accepts only reviewed Playwriter package-runner commands", () => {
  assert.deepEqual(validatePlaywriterCommand(["npx", "playwriter@0.8.0"]), [
    "npx", "playwriter@0.8.0",
  ]);
  assert.deepEqual(validatePlaywriterCommand(["bun", "x", "playwriter@0.8.0"]), [
    "bun", "x", "playwriter@0.8.0",
  ]);
  for (const unreviewed of ["playwriter@latest", "playwriter@0.5.0"]) {
    assert.throws(
      () => validatePlaywriterCommand(["npx", unreviewed]),
      /reviewed Playwriter package shape/,
    );
  }
  assert.throws(
    () => validatePlaywriterCommand(["sh", "-c", "playwriter@0.8.0"]),
    /reviewed Playwriter package shape/,
  );
});

test("defaults Playwriter telemetry off but keeps an explicit operator choice", () => {
  assert.deepEqual(withTelemetryOptOut({ PATH: "/bin" }), {
    PATH: "/bin", PLAYWRITER_TELEMETRY: "0", DO_NOT_TRACK: "1",
  });
  assert.deepEqual(withTelemetryOptOut({ PLAYWRITER_TELEMETRY: "1" }), {
    PLAYWRITER_TELEMETRY: "1",
  });
});

test("proves both relay version and token enforcement", async (t) => {
  const token = "a".repeat(32);
  const server = createServer((request, response) => {
    if (request.url === "/version") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"version":"0.8.0"}');
      return;
    }
    const url = new URL(request.url, "http://127.0.0.1");
    response.writeHead(url.searchParams.get("token") === token ? 404 : 401);
    response.end();
  });
  await new Promise((resolvePromise) => server.listen(0, "127.0.0.1", resolvePromise));
  t.after(() => server.close());
  const address = server.address();

  assert.deepEqual(
    await probeAuthenticatedRelay({ token, port: address.port }),
    { reachable: true, ready: true },
  );
  assert.deepEqual(
    await probeAuthenticatedRelay({ token: "b".repeat(32), port: address.port }),
    { reachable: true, ready: false },
  );
});

test("removes only runtime directories with matching ownership evidence", (t) => {
  const tempRoot = mkdtempSync(join(tmpdir(), "aidevops-playwriter-relay-"));
  const runtime = createPrivateRuntime(tempRoot, "owned-token");
  t.after(() => {
    try { cleanupPrivateRuntime(runtime); } catch {}
  });
  assert.equal(readFileSync(runtime.markerPath, "utf8"), "owned-token");
  writeFileSync(runtime.markerPath, "foreign-token");
  assert.throws(() => cleanupPrivateRuntime(runtime), /matching ownership evidence/);
  writeFileSync(runtime.markerPath, "owned-token");
  cleanupPrivateRuntime(runtime);
});

test("stops every member of an owned relay process group", { skip: !POSIX }, async (t) => {
  const { groupId, descendantPid } = await startSyntheticGroup(t);
  assert.equal(processGroupAlive(groupId), true);
  assert.equal(await terminateProcessGroup(groupId, { graceMs: 200 }), true);
  assert.equal(processGroupAlive(groupId), false);
  assert.equal(alive(descendantPid), false, "SIGTERM-resistant descendant must not be orphaned");
  assert.equal(await terminateProcessGroup(groupId), true, "an absent group is already stopped");
  await assert.rejects(terminateProcessGroup(process.pid), /invalid process group/);
});

test("reconciles an owned relay left by a dead supervisor", { skip: !POSIX }, async (t) => {
  const parent = privateRuntimeParent(mkdtempSync(join(tmpdir(), "aidevops-playwriter-relay-")));
  const { groupId, descendantPid } = await startSyntheticGroup(t, GUARDIAN_ARGS);
  const session = writeSession(parent, deadPid(), { relayGroupId: groupId });

  assert.deepEqual(await reconcileStaleRelays(parent), [session.name]);
  assert.equal(processGroupAlive(groupId), false);
  assert.equal(alive(descendantPid), false);
  assert.equal(existsSync(session.directory), false);
});

test("never stops a relay without proven stale ownership", { skip: !POSIX }, async (t) => {
  const parent = privateRuntimeParent(mkdtempSync(join(tmpdir(), "aidevops-playwriter-relay-")));
  // A listener whose command is not the guardian shape, e.g. an external relay.
  const foreign = await startSyntheticGroup(t);
  const foreignSession = writeSession(parent, deadPid(), { relayGroupId: foreign.groupId });
  // A matching relay whose supervisor is still alive (a parallel session).
  const live = await startSyntheticGroup(t, GUARDIAN_ARGS);
  const liveSession = writeSession(parent, process.pid, { relayGroupId: live.groupId });
  // A relay recorded as not owned by its session.
  const external = await startSyntheticGroup(t, GUARDIAN_ARGS);
  writeSession(parent, deadPid(), { relayGroupId: external.groupId, owned: false });

  await reconcileStaleRelays(parent);
  for (const group of [foreign, live, external]) {
    assert.equal(processGroupAlive(group.groupId), true);
    assert.equal(alive(group.descendantPid), true);
  }
  assert.equal(existsSync(foreignSession.directory), true);
  assert.equal(existsSync(liveSession.directory), true);
});
