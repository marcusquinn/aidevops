// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { createRootSessionGreetingGate, openCodeV1SessionLookup } from "../root-session-greeting-gate.mjs";

test("root-session greeting gate keeps root sessions and skips children silently", async () => {
  const logs = [];
  const lookups = [];
  const sessions = { root: { id: "root" }, child: { id: "child", parentID: "root" } };
  const gate = createRootSessionGreetingGate({
    getSession: async (sessionID) => {
      lookups.push(sessionID);
      return sessions[sessionID];
    },
    log: (level, message) => logs.push(`${level} ${message}`),
  });

  // Every root request keeps the greeting (stable prefix); a parent never
  // changes, so each session is looked up once.
  assert.equal(await gate({ sessionID: "root" }), true);
  assert.equal(await gate({ sessionID: "root" }), true);
  assert.equal(await gate({ sessionID: "child" }), false);
  assert.equal(await gate({ sessionID: "child" }), false);
  assert.equal(await gate({}), false);
  assert.deepEqual(lookups, ["root", "child"]);
  assert.deepEqual(logs, []);
});

test("OpenCode 1 session lookup adapts the SDK client and surfaces errors", async () => {
  assert.equal(openCodeV1SessionLookup(undefined), undefined);
  assert.equal(openCodeV1SessionLookup({ session: {} }), undefined);

  const paths = [];
  const lookup = openCodeV1SessionLookup({
    session: {
      get: async ({ path }) => {
        paths.push(path.id);
        if (path.id === "broken") return { error: { message: "not found" } };
        return { data: { id: path.id, parentID: path.id === "child" ? "root" : undefined } };
      },
    },
  });
  const gate = createRootSessionGreetingGate({ getSession: lookup });
  assert.equal(await gate({ sessionID: "root" }), true);
  assert.equal(await gate({ sessionID: "child" }), false);
  // A failed lookup must never be mistaken for a root session, and is retried.
  assert.equal(await gate({ sessionID: "broken" }), false);
  assert.equal(await gate({ sessionID: "broken" }), false);
  assert.deepEqual(paths, ["root", "child", "broken", "broken"]);

  // Without a session client the gate stays closed.
  assert.equal(await createRootSessionGreetingGate({ getSession: undefined })({ sessionID: "root" }), false);
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
