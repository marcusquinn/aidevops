// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { createSessionStartGreetingGate } from "../ttsr.mjs";
import { createRootSessionGreetingGate } from "../root-session-greeting-gate.mjs";

test("session-start greeting gate stays disabled without a session client", async () => {
  const missingClientGate = createSessionStartGreetingGate();
  const incompleteClientGate = createSessionStartGreetingGate({ session: {} });

  assert.equal(await missingClientGate({ sessionID: "root" }), false);
  assert.equal(await incompleteClientGate({ sessionID: "root" }), false);
});

test("session-start greeting gate uses a valid session client", async () => {
  let calls = 0;
  const gate = createSessionStartGreetingGate({
    session: {
      get: async ({ path }) => {
        calls += 1;
        assert.equal(path.id, "root");
        return { data: { id: "root" } };
      },
    },
  });

  assert.equal(await gate({ sessionID: "root" }), true);
  assert.equal(await gate({ sessionID: "root" }), false);
  assert.equal(calls, 1);
});

test("V2 root-session greeting gate keeps root sessions and skips children silently", async () => {
  const logs = [];
  const sessions = { root: { id: "root" }, child: { id: "child", parentID: "root" } };
  const gate = createRootSessionGreetingGate({
    getSession: async (sessionID) => sessions[sessionID],
    log: (level, message) => logs.push(`${level} ${message}`),
  });

  assert.equal(await gate({ sessionID: "root" }), true);
  assert.equal(await gate({ sessionID: "root" }), true);
  assert.equal(await gate({ sessionID: "child" }), false);
  assert.equal(await gate({}), false);
  assert.deepEqual(logs, []);
});

test("V2 root-session greeting gate logs unexpected skips once per session", async () => {
  const logs = [];
  let headless = true;
  const gate = createRootSessionGreetingGate({
    getSession: async () => {
      throw new Error("service unavailable");
    },
    isHeadless: () => headless,
    log: (level, message) => logs.push(`${level} ${message}`),
  });

  assert.equal(await gate({ sessionID: "ses_a" }), false);
  assert.equal(await gate({ sessionID: "ses_a" }), false);
  headless = false;
  assert.equal(await gate({ sessionID: "ses_b" }), false);
  assert.equal(await gate({ sessionID: "ses_b" }), false);
  assert.deepEqual(logs, [
    "INFO Session greeting skipped for ses_a: headless environment",
    "INFO Session greeting skipped for ses_b: session lookup failed (service unavailable)",
  ]);
});
