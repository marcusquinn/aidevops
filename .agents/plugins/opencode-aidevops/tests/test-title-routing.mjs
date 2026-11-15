// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
//
// GH#34125 follow-up: title generation bypasses chat.params entirely (no hook
// visibility), so bound sessions must have agent.title.model/small_model
// forced onto a local provider at config time.

import { test } from "node:test";
import assert from "node:assert/strict";

import { applyLocalOnlyTitleRouting } from "../title-routing.mjs";

const bound = { bound: true, localProviders: ["mac-local"] };
const unbound = { bound: false, localProviders: [] };

test("bound session with no title/small_model pin gets both forced to the local primary", () => {
  const config = { model: "mac-local/qwen3-vl-30b-a3b" };
  assert.equal(applyLocalOnlyTitleRouting(config, { policy: bound }), true);
  assert.equal(config.agent.title.model, "mac-local/qwen3-vl-30b-a3b");
  assert.equal(config.small_model, "mac-local/qwen3-vl-30b-a3b");
});

test("bound session overrides an existing non-local title/small_model pin (absolute, unlike compaction)", () => {
  const config = {
    model: "mac-local/qwen3-vl-30b-a3b",
    small_model: "anthropic/claude-haiku-5-5",
    agent: { title: { model: "anthropic/claude-haiku-5-5" } },
  };
  assert.equal(applyLocalOnlyTitleRouting(config, { policy: bound }), true);
  assert.equal(config.agent.title.model, "mac-local/qwen3-vl-30b-a3b");
  assert.equal(config.small_model, "mac-local/qwen3-vl-30b-a3b");
});

test("bound session leaves an already-local title/small_model pin untouched", () => {
  const config = {
    model: "mac-local/qwen3-vl-30b-a3b",
    small_model: "mac-local/qwen3-vl-30b-a3b",
    agent: { title: { model: "mac-local/qwen3-vl-30b-a3b" } },
  };
  assert.equal(applyLocalOnlyTitleRouting(config, { policy: bound }), false);
  assert.equal(config.agent.title.model, "mac-local/qwen3-vl-30b-a3b");
});

test("bound session with a non-local primary model forces nothing (egress gate still covers the main turn)", () => {
  const config = { model: "anthropic/claude-haiku-5-5" };
  assert.equal(applyLocalOnlyTitleRouting(config, { policy: bound }), false);
  assert.equal(config.agent?.title?.model, undefined);
  assert.equal(config.small_model, undefined);
});

test("unbound session is never touched", () => {
  const config = { model: "anthropic/claude-haiku-5-5" };
  assert.equal(applyLocalOnlyTitleRouting(config, { policy: unbound }), false);
  assert.equal(config.agent, undefined);
  assert.equal(config.small_model, undefined);
});

test("missing config is a no-op", () => {
  assert.equal(applyLocalOnlyTitleRouting(null, { policy: bound }), false);
});
