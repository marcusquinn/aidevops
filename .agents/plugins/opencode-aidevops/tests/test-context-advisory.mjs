// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import { checkTokenAdvisory, getTokenAdvisoryInitial } from "../ttsr.mjs";

function messages(total, sessionID = "session-1") {
  return [{ info: { role: "assistant", sessionID, tokens: { input: total } } }];
}

test("token advisory starts at 400K for ordinary models", () => {
  const input = { model: { modelID: "gpt-5.6-sol" } };
  const state = new Map();
  assert.equal(getTokenAdvisoryInitial(input), 400000);
  assert.equal(checkTokenAdvisory(messages(399999), state, input, () => false), null);
  assert.equal(checkTokenAdvisory(messages(400000), state, input, () => false)?.total, 400000);
  assert.equal(checkTokenAdvisory(messages(449999), state, input, () => false), null);
  assert.equal(checkTokenAdvisory(messages(450000), state, input, () => false)?.total, 450000);
});

test("Astra, Grok, and Gemini advisories start at 500K", () => {
  for (const modelID of ["gpt-6-astra", "grok-4", "gemini-3-pro"]) {
    const input = { model: { modelID } };
    const state = new Map();
    assert.equal(getTokenAdvisoryInitial(input), 500000);
    assert.equal(checkTokenAdvisory(messages(499999), state, input, () => false), null);
    assert.equal(checkTokenAdvisory(messages(500000), state, input, () => false)?.total, 500000);
  }
});

test("token advisory remains disabled for headless sessions", () => {
  const input = { model: { modelID: "gpt-5.6-sol" } };
  assert.equal(checkTokenAdvisory(messages(600000), new Map(), input, () => true), null);
});
