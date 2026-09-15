// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { after, test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { startOAuthCallbackServer } from "../oauth-pool-callback.mjs";

const tempBase = process.env.AIDEVOPS_TEMP_DIR
  || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
mkdirSync(tempBase, { recursive: true, mode: 0o700 });
const testRoot = mkdtempSync(join(tempBase, "oauth-callback-lock-test-"));
process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_DIR = join(testRoot, "callback.lock");
after(() => {
  delete process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_DIR;
  delete process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_LEASE_MS;
  rmSync(testRoot, { recursive: true, force: true });
});

test("callback server preserves the public re-export and captures valid codes", async () => {
  const server = startOAuthCallbackServer("expected-state");

  try {
    assert.equal(await server.ready, true);
    const response = await fetch(
      "http://127.0.0.1:1455/auth/callback?code=test-code&state=expected-state",
    );

    assert.equal(response.status, 200);
    assert.match(await response.text(), /Authorization Successful/);
    assert.equal(await server.promise, "test-code");
  } finally {
    server.close();
  }
});

test("callback server rejects mismatched OAuth state", async () => {
  const server = startOAuthCallbackServer("expected-state");
  const rejection = assert.rejects(server.promise, /OAuth state mismatch/);

  try {
    assert.equal(await server.ready, true);
    const response = await fetch(
      "http://127.0.0.1:1455/auth/callback?code=test-code&state=wrong-state",
    );

    assert.equal(response.status, 400);
    await rejection;
  } finally {
    server.close();
  }
});

test("callback server escapes OAuth errors and rejects the pending code", async () => {
  const server = startOAuthCallbackServer("expected-state");
  const unsafeError = "<img src=x onerror=alert(1)>";
  const rejection = assert.rejects(server.promise, /OAuth error: <img src=x onerror=alert\(1\)>/);

  try {
    assert.equal(await server.ready, true);
    const description = encodeURIComponent('<script>"not allowed"</script>');
    const error = encodeURIComponent(unsafeError);
    const response = await fetch(
      `http://127.0.0.1:1455/auth/callback?error=${error}&error_description=${description}&state=expected-state`,
    );
    const body = await response.text();

    assert.equal(response.status, 200);
    assert.match(body, /&lt;img src=x onerror=alert\(1\)&gt;/);
    assert.match(body, /&lt;script&gt;&quot;not allowed&quot;&lt;\/script&gt;/);
    assert.equal(body.includes(unsafeError), false);
    assert.doesNotMatch(body, /<script>/);
    await rejection;

    const rebound = startOAuthCallbackServer("rebound-state");
    try {
      assert.equal(await rebound.ready, true);
    } finally {
      rebound.close();
    }
  } finally {
    server.close();
  }
});

test("closing the callback server releases the loopback port", async () => {
  const first = startOAuthCallbackServer("first-state");
  assert.equal(await first.ready, true);
  first.close();

  const second = startOAuthCallbackServer("second-state");
  try {
    assert.equal(await second.ready, true);
  } finally {
    second.close();
  }
});

test("concurrent interactive logins serialize on the callback lock", async () => {
  const first = startOAuthCallbackServer("first-state");
  const second = startOAuthCallbackServer("second-state");

  try {
    assert.equal(await first.ready, true);
    let secondSettled = false;
    void second.ready.then(() => { secondSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(secondSettled, false);

    first.close();
    const secondReady = await Promise.race([
      second.ready,
      new Promise((_, reject) => setTimeout(() => reject(new Error("callback lock timeout")), 2_000)),
    ]);
    assert.equal(secondReady, true);
  } finally {
    first.close();
    second.close();
  }
});

test("expired incomplete callback locks are reclaimed", async () => {
  const lockDir = process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_DIR;
  mkdirSync(lockDir, { mode: 0o700 });
  const old = new Date(Date.now() - 1_000);
  utimesSync(lockDir, old, old);
  process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_LEASE_MS = "20";
  const server = startOAuthCallbackServer("incomplete-state");
  try {
    assert.equal(await server.ready, true);
  } finally {
    server.close();
    delete process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_LEASE_MS;
  }
});

test("expired locks do not trust a reused live PID", async () => {
  const lockDir = process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_DIR;
  mkdirSync(lockDir, { mode: 0o700 });
  writeFileSync(
    join(lockDir, "pid"),
    `${JSON.stringify({ pid: process.pid, token: "former-owner" })}\n`,
    { mode: 0o600 },
  );
  const old = new Date(Date.now() - 1_000);
  utimesSync(lockDir, old, old);
  process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_LEASE_MS = "20";
  const server = startOAuthCallbackServer("reused-pid-state");
  try {
    assert.equal(await server.ready, true);
  } finally {
    server.close();
    delete process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_LEASE_MS;
  }
});
