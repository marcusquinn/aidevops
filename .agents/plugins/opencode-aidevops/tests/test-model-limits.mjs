// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Tests for model-limits.mjs (t2435 — AIDEVOPS_OPUS_47_CONTEXT env override).
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-model-limits.mjs
//
// Scope:
//   - resolveOpus47Context() honours env var across the full validity matrix
//   - describeOpus47Override() returns the right kind for each input class
//   - CLAUDE_MODEL_LIMITS table shape is intact (regression guard)
// ---------------------------------------------------------------------------

import { test, describe, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";

import {
  resolveOpus47Context,
  describeOpus47Override,
  OPUS_47_CONTEXT_DEFAULT,
  OPUS_47_CONTEXT_MAX,
  CLAUDE_MODEL_LIMITS,
} from "../model-limits.mjs";

// ---------------------------------------------------------------------------
// resolveOpus47Context — input → output matrix
// ---------------------------------------------------------------------------

describe("resolveOpus47Context", () => {
  let originalEnv;

  beforeEach(() => {
    originalEnv = process.env.AIDEVOPS_OPUS_47_CONTEXT;
    delete process.env.AIDEVOPS_OPUS_47_CONTEXT;
  });

  afterEach(() => {
    if (originalEnv !== undefined) {
      process.env.AIDEVOPS_OPUS_47_CONTEXT = originalEnv;
    } else {
      delete process.env.AIDEVOPS_OPUS_47_CONTEXT;
    }
  });

  test("unset env → default 250000", () => {
    assert.equal(resolveOpus47Context(), OPUS_47_CONTEXT_DEFAULT);
    assert.equal(OPUS_47_CONTEXT_DEFAULT, 250000);
  });

  test("empty string → default 250000", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "";
    assert.equal(resolveOpus47Context(), OPUS_47_CONTEXT_DEFAULT);
  });

  test("valid override 1000000 → 1000000", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "1000000";
    assert.equal(resolveOpus47Context(), 1000000);
  });

  test("valid override 500000 → 500000", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "500000";
    assert.equal(resolveOpus47Context(), 500000);
  });

  test("zero → default 250000 (treated as invalid)", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "0";
    assert.equal(resolveOpus47Context(), OPUS_47_CONTEXT_DEFAULT);
  });

  test("negative → default 250000", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "-100";
    assert.equal(resolveOpus47Context(), OPUS_47_CONTEXT_DEFAULT);
  });

  test("non-numeric → default 250000", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "foo";
    assert.equal(resolveOpus47Context(), OPUS_47_CONTEXT_DEFAULT);
  });

  test("garbage with leading digits → parsed as the leading int", () => {
    // parseInt("123abc", 10) === 123. We don't try to be stricter than
    // parseInt — if a user writes garbage that parses to a positive int,
    // they get that int. The MRCR-collapse warning will educate them.
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "300000abc";
    assert.equal(resolveOpus47Context(), 300000);
  });

  test("above MAX → clamped to OPUS_47_CONTEXT_MAX", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "5000000";
    assert.equal(resolveOpus47Context(), OPUS_47_CONTEXT_MAX);
    assert.equal(OPUS_47_CONTEXT_MAX, 1000000);
  });

  test("at MAX exactly → MAX", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "1000000";
    assert.equal(resolveOpus47Context(), OPUS_47_CONTEXT_MAX);
  });
});

// ---------------------------------------------------------------------------
// describeOpus47Override — classification of env-var states
// ---------------------------------------------------------------------------

describe("describeOpus47Override", () => {
  let originalEnv;

  beforeEach(() => {
    originalEnv = process.env.AIDEVOPS_OPUS_47_CONTEXT;
    delete process.env.AIDEVOPS_OPUS_47_CONTEXT;
  });

  afterEach(() => {
    if (originalEnv !== undefined) {
      process.env.AIDEVOPS_OPUS_47_CONTEXT = originalEnv;
    } else {
      delete process.env.AIDEVOPS_OPUS_47_CONTEXT;
    }
  });

  test("unset → null (silent default path, no warn)", () => {
    assert.equal(describeOpus47Override(), null);
  });

  test("empty → null (silent default path, no warn)", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "";
    assert.equal(describeOpus47Override(), null);
  });

  test("explicit default → null (no-op, no warn)", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "250000";
    assert.equal(describeOpus47Override(), null);
  });

  test("valid override → kind=applied", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "1000000";
    const desc = describeOpus47Override();
    assert.deepEqual(desc, { kind: "applied", raw: "1000000", resolved: 1000000 });
  });

  test("above MAX → kind=clamped", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "5000000";
    const desc = describeOpus47Override();
    assert.deepEqual(desc, { kind: "clamped", raw: "5000000", resolved: OPUS_47_CONTEXT_MAX });
  });

  test("non-numeric → kind=invalid", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "foo";
    const desc = describeOpus47Override();
    assert.deepEqual(desc, { kind: "invalid", raw: "foo", resolved: OPUS_47_CONTEXT_DEFAULT });
  });

  test("zero → kind=invalid", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "0";
    const desc = describeOpus47Override();
    assert.deepEqual(desc, { kind: "invalid", raw: "0", resolved: OPUS_47_CONTEXT_DEFAULT });
  });

  test("negative → kind=invalid", () => {
    process.env.AIDEVOPS_OPUS_47_CONTEXT = "-5";
    const desc = describeOpus47Override();
    assert.deepEqual(desc, { kind: "invalid", raw: "-5", resolved: OPUS_47_CONTEXT_DEFAULT });
  });
});

// ---------------------------------------------------------------------------
// CLAUDE_MODEL_LIMITS — regression guard on table shape
// ---------------------------------------------------------------------------

describe("CLAUDE_MODEL_LIMITS table", () => {
  test("contains all six expected Claude model ids", () => {
    const expected = [
      "claude-haiku-4-5",
      "claude-sonnet-4-5",
      "claude-sonnet-4-6",
      "claude-opus-4-5",
      "claude-opus-4-6",
      "claude-opus-4-7",
    ];
    for (const id of expected) {
      assert.ok(
        CLAUDE_MODEL_LIMITS[id],
        `missing limit entry for ${id}`,
      );
      assert.equal(typeof CLAUDE_MODEL_LIMITS[id].context, "number");
      assert.equal(typeof CLAUDE_MODEL_LIMITS[id].output, "number");
      assert.ok(CLAUDE_MODEL_LIMITS[id].context > 0);
      assert.ok(CLAUDE_MODEL_LIMITS[id].output > 0);
    }
  });

  test("opus-4-7 context matches resolveOpus47Context() at module-load time", () => {
    // The table is computed once at module load. Confirm it didn't drift
    // from the resolver function.
    assert.equal(
      CLAUDE_MODEL_LIMITS["claude-opus-4-7"].context,
      resolveOpus47Context(),
      "opus-4-7 context in table != resolveOpus47Context()",
    );
  });

  test("non-opus-4-7 entries are not affected by env var", () => {
    // Sanity: the env var is opus-4-7-specific. Other models keep their
    // hard-coded limits regardless.
    assert.equal(CLAUDE_MODEL_LIMITS["claude-opus-4-6"].context, 1000000);
    assert.equal(CLAUDE_MODEL_LIMITS["claude-haiku-4-5"].context, 1000000);
  });
});
