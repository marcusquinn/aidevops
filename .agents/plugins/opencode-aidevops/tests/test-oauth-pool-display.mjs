// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  formatDuration, formatAgo, poolActionCheck,
  poolActionRemove, poolActionResetCooldowns,
  poolActionAssignPending, poolActionSetPriority,
  poolAccountAddCommand, poolActionRotate,
} from "../oauth-pool-display.mjs";
import { poolActionCheck as healthCheckAction } from "../oauth-pool-health-check.mjs";
import {
  poolActionRemove as accountRemoveAction,
  poolActionResetCooldowns as accountResetCooldownsAction,
  poolActionAssignPending as accountAssignPendingAction,
  poolActionSetPriority as accountSetPriorityAction,
} from "../oauth-pool-account-actions.mjs";

test("display formatting keeps minute and hour output", () => {
  assert.equal(formatDuration(59_999), "0m");
  assert.equal(formatDuration(3_900_000), "1h 5m");
  assert.equal(formatAgo(3_900_000), "1h 5m ago");
});

test("display module preserves the health-check action export", () => {
  assert.equal(poolActionCheck, healthCheckAction);
});

test("display module preserves account action exports", () => {
  assert.equal(poolActionRemove, accountRemoveAction);
  assert.equal(poolActionResetCooldowns, accountResetCooldownsAction);
  assert.equal(poolActionAssignPending, accountAssignPendingAction);
  assert.equal(poolActionSetPriority, accountSetPriorityAction);
});

test("pool remediation uses the supported account-add command", async () => {
  assert.equal(poolAccountAddCommand("openai"), "aidevops model-accounts-pool add openai");
  assert.equal(poolAccountAddCommand("unknown"), "aidevops model-accounts-pool add anthropic");
  assert.match(
    await poolActionRotate({}, "openai", [], () => async () => true),
    /aidevops model-accounts-pool add openai/,
  );
});

test("V2 pool remediation stays isolated and never uses V1 OpenAI device login", () => {
  const oldProfile = process.env.AIDEVOPS_OPENCODE_PROFILE;
  const oldPool = process.env.AIDEVOPS_OAUTH_POOL_FILE;
  try {
    process.env.AIDEVOPS_OPENCODE_PROFILE = "v2";
    process.env.AIDEVOPS_OAUTH_POOL_FILE = "/isolated/opencode-v2/oauth-pool.json";
    assert.equal(poolAccountAddCommand("anthropic"),
      "AIDEVOPS_OAUTH_POOL_FILE='/isolated/opencode-v2/oauth-pool.json' aidevops model-accounts-pool add anthropic");
    assert.equal(poolAccountAddCommand("openai"),
      "AIDEVOPS_OAUTH_POOL_FILE='/isolated/opencode-v2/oauth-pool.json' AIDEVOPS_OPENAI_ADD_MODE=callback aidevops model-accounts-pool add openai");
    assert.match(poolAccountAddCommand("google"), /not connected to provider requests/);
    delete process.env.AIDEVOPS_OAUTH_POOL_FILE;
    assert.match(poolAccountAddCommand("openai"), /isolated V2 pool setup/);
  } finally {
    if (oldProfile === undefined) delete process.env.AIDEVOPS_OPENCODE_PROFILE;
    else process.env.AIDEVOPS_OPENCODE_PROFILE = oldProfile;
    if (oldPool === undefined) delete process.env.AIDEVOPS_OAUTH_POOL_FILE;
    else process.env.AIDEVOPS_OAUTH_POOL_FILE = oldPool;
  }
});
