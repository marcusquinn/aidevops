// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";

import { getPricing } from "../observability.mjs";

test("GPT-5.6 pricing uses published API rates", () => {
  assert.deepEqual(getPricing("gpt-5.6-sol"), {
    input: 5.0, output: 30.0, cacheRead: 0.50, cacheWrite: 6.25,
  });
  assert.deepEqual(getPricing("gpt-5.6-terra"), {
    input: 2.50, output: 15.0, cacheRead: 0.25, cacheWrite: 3.125,
  });
  assert.deepEqual(getPricing("gpt-5.6-luna"), {
    input: 1.0, output: 6.0, cacheRead: 0.10, cacheWrite: 1.25,
  });
});

test("Sol Pro does not inherit unpublished standard Sol pricing", () => {
  assert.deepEqual(getPricing("gpt-5.6-sol-pro"), {
    input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75,
  });
});
