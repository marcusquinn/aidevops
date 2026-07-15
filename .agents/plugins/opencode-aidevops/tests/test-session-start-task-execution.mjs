// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { buildSessionStartGreetingInstruction } from "../ttsr.mjs";

const instruction = buildSessionStartGreetingInstruction("/missing", () => "");

assert.match(instruction, /greeting is only a required prefix/);
assert.match(instruction, /SAME assistant turn/);
assert.match(instruction, /Tool calls may precede it/);
assert.match(instruction, /Never emit a greeting-only response/);
assert.match(instruction, /Call the appropriate tools immediately, before visible text if necessary/);
assert.match(instruction, /Do not claim that tool access is unavailable without first attempting/);
assert.doesNotMatch(instruction, /before tool calls, status updates/);

const paths = {
  version: "/agents/VERSION",
};
const readVersion = (path) => path === paths.version ? "3.32.122\n" : "";
const staleCache = {
  output: "aidevops v3.32.118 running in OpenCode v1.17.20 | local",
  mtimeMs: 1_000,
};
const freshCache = {
  output: "aidevops v3.32.122 running in OpenCode v1.18.1 | local",
  mtimeMs: 9_500,
};

const staleInstruction = buildSessionStartGreetingInstruction("/agents", readVersion, {
  now: () => 10_000,
  refreshTtlMs: 1_000,
  readGreetingCache: () => staleCache,
});
assert.match(staleInstruction, /We're running aidevops v3\.32\.122\./);
assert.doesNotMatch(staleInstruction, /3\.32\.118|1\.17\.20/);

const freshInstruction = buildSessionStartGreetingInstruction("/agents", readVersion, {
  now: () => 10_000,
  refreshTtlMs: 1_000,
  initializedAtMs: 9_000,
  readGreetingCache: () => freshCache,
});
assert.match(freshInstruction, /We're running aidevops v3\.32\.122 in OpenCode v1\.18\.1\./);

const mismatchedInstruction = buildSessionStartGreetingInstruction("/agents", readVersion, {
  now: () => 10_000,
  refreshTtlMs: 1_000,
  readGreetingCache: () => ({ ...staleCache, mtimeMs: 9_500 }),
});
assert.match(mismatchedInstruction, /We're running aidevops v3\.32\.122\./);
assert.doesNotMatch(mismatchedInstruction, /3\.32\.118|1\.17\.20/);

const runtimeUpgradeInstruction = buildSessionStartGreetingInstruction("/agents", readVersion, {
  now: () => 10_000,
  refreshTtlMs: 1_000,
  initializedAtMs: 9_750,
  readGreetingCache: () => ({
    output: "aidevops v3.32.122 running in OpenCode v1.17.20 | local",
    mtimeMs: 9_500,
  }),
});
assert.match(runtimeUpgradeInstruction, /We're running aidevops v3\.32\.122\./);
assert.doesNotMatch(runtimeUpgradeInstruction, /1\.17\.20/);

console.log("session-start task execution instruction tests passed");
