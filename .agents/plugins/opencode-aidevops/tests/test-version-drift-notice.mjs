// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { createVersionDriftNotice, isDeployedNewer } from "../deployed-version.mjs";

test("isDeployedNewer compares numerically and only when strictly newer", () => {
  assert.equal(isDeployedNewer("3.39.221", "3.39.222"), true);
  assert.equal(isDeployedNewer("3.39.9", "3.39.10"), true);
  assert.equal(isDeployedNewer("3.39.222", "3.39.222"), false);
  assert.equal(isDeployedNewer("3.39.222", "3.39.221"), false);
  assert.equal(isDeployedNewer("", "3.39.222"), false);
  assert.equal(isDeployedNewer("3.39.222", "garbage"), false);
});

test("notice emits once, is throttled, and skips when versions match", async () => {
  const toasts = [];
  const client = { tui: { showToast: async (t) => toasts.push(t) } };
  let clock = 1000;
  let deployed = "3.39.221";
  const check = createVersionDriftNotice({
    client, loadedVersion: "3.39.221", now: () => clock, intervalMs: 100, read: () => deployed,
  });
  assert.equal(await check(), false);
  deployed = "3.39.222";
  assert.equal(await check(), false, "throttled within interval");
  clock += 200;
  assert.equal(await check(), true);
  clock += 200;
  assert.equal(await check(), false, "only once per session");
  assert.equal(toasts.length, 1);
  assert.match(toasts[0].body.message, /v3\.39\.222 was deployed.*running v3\.39\.221/);
});
