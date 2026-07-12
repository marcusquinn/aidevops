// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { createSessionStartGreetingGate } from "../ttsr.mjs";

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
