// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Test suite for timing-tracing.mjs (t2184)
// ---------------------------------------------------------------------------
// Runs under the built-in `node:test` runner. No external deps.
//
//   node --test .agents/plugins/opencode-aidevops/tests/
//
// or to run just this file:
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-timing-tracing.mjs
//
// Scope: pure-function coverage of recordToolStart / consumeToolDuration.
// Real hook wiring (toolExecuteBefore → toolExecuteAfter) is verified
// indirectly via end-to-end sqlite checks in the manual Jaeger run-book
// (see reference/observability.md).
// ---------------------------------------------------------------------------

import { test, describe, beforeEach } from "node:test";
import assert from "node:assert/strict";

import {
  recordToolStart,
  consumeToolDuration,
  _size,
  _clear,
} from "../timing-tracing.mjs";

// ---------------------------------------------------------------------------
// Basic record/consume cycle
// ---------------------------------------------------------------------------

describe("recordToolStart / consumeToolDuration", () => {
  beforeEach(() => {
    _clear();
  });

  test("record then consume returns a non-negative integer", () => {
    recordToolStart("call-1");
    const dur = consumeToolDuration("call-1");
    assert.equal(typeof dur, "number");
    assert.ok(dur >= 0, `expected ≥0, got ${dur}`);
    // Must be plausibly small — we just called record and consume
    // back-to-back, so anything over a second implies the store is broken.
    assert.ok(dur < 1000, `expected <1000ms, got ${dur}`);
  });

  test("consume twice returns null on second call", () => {
    recordToolStart("call-dup");
    const first = consumeToolDuration("call-dup");
    const second = consumeToolDuration("call-dup");
    assert.equal(typeof first, "number");
    assert.equal(second, null);
  });

  test("consume for unknown callID returns null", () => {
    assert.equal(consumeToolDuration("never-recorded"), null);
  });

  test("empty callID is a no-op on record and returns null on consume", () => {
    recordToolStart("");
    assert.equal(_size(), 0);
    assert.equal(consumeToolDuration(""), null);
  });

  test("null/undefined-equivalent falsy callIDs return null", () => {
    // recordToolStart treats all falsy values as no-op; consumeToolDuration
    // guards with the same falsy check. Belt-and-braces coverage so a future
    // edit that drops either guard gets caught immediately.
    recordToolStart(undefined);
    recordToolStart(null);
    recordToolStart(0);
    assert.equal(_size(), 0);
    assert.equal(consumeToolDuration(undefined), null);
    assert.equal(consumeToolDuration(null), null);
    assert.equal(consumeToolDuration(0), null);
  });

  test("consume correctly measures an elapsed delay", async () => {
    recordToolStart("slow-1");
    await new Promise((r) => setTimeout(r, 25));
    const dur = consumeToolDuration("slow-1");
    // Allow wide slack for loaded CI runners but enforce the lower bound.
    assert.ok(dur >= 20, `expected ≥20ms, got ${dur}`);
    assert.ok(dur < 5000, `expected <5000ms, got ${dur}`);
  });
});

// ---------------------------------------------------------------------------
// LRU prune behavior
// ---------------------------------------------------------------------------

describe("LRU prune at size > 5000", () => {
  beforeEach(() => {
    _clear();
  });

  test("size below threshold: no prune", () => {
    for (let i = 0; i < 100; i++) recordToolStart(`cid-${i}`);
    assert.equal(_size(), 100);
  });

  test("size crosses 5000: prunes to 2500 + 1 fresh entry", () => {
    // Fill to exactly 5000 — still under the trigger.
    for (let i = 0; i < 5000; i++) recordToolStart(`cid-${i}`);
    assert.equal(_size(), 5000);

    // 5001st insert triggers prune. Implementation drops the oldest 2500,
    // then inserts the new entry — leaving 5000 - 2500 + 1 = 2501.
    recordToolStart("cid-5000");
    assert.equal(_size(), 2501);
  });

  test("after prune, the fresh callID is still consumable", () => {
    for (let i = 0; i < 5001; i++) recordToolStart(`cid-${i}`);
    const dur = consumeToolDuration("cid-5000");
    assert.equal(typeof dur, "number");
    assert.ok(dur >= 0);
  });
});
