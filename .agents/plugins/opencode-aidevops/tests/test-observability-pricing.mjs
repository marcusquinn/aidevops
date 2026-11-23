// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";

import { getPricing } from "../observability.mjs";
import {
  calculateCost, getPricingProvenance, getPromptContextTokens, PRICING_VERSION,
} from "../observability-pricing.mjs";

test("GPT-6 Astra and GPT-5.6 pricing use published Standard short-context API rates", () => {
  assert.deepEqual(getPricing("openai/gpt-6-astra"), {
    input: 10.0, output: 50.0, cacheRead: 1.0, cacheWrite: 12.50,
  });
  assert.deepEqual(getPricing("gpt-5.6-sol"), {
    input: 4.0, output: 20.0, cacheRead: 0.40, cacheWrite: 5.0,
  });
  assert.deepEqual(getPricing("gpt-5.6-terra"), {
    input: 2.0, output: 12.0, cacheRead: 0.20, cacheWrite: 2.50,
  });
  assert.deepEqual(getPricing("gpt-5.6-luna"), {
    input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25,
  });
  assert.deepEqual(getPricing("openai/gpt-6.1-sol"), {
    input: 2.0, output: 10.0, cacheRead: 0.10, cacheWrite: 2.50,
  });
  assert.deepEqual(getPricing("openai/gpt-6.1-terra"), {
    input: 1.0, output: 5.0, cacheRead: 0.05, cacheWrite: 1.25,
  });
  assert.deepEqual(getPricing("openai/gpt-6-sol"), {
    input: 2.0, output: 10.0, cacheRead: 0.20, cacheWrite: 2.50,
  });
  assert.deepEqual(getPricing("openai/gpt-6-luna"), {
    input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125,
  });
  assert.equal(getPricing("opencode-go/deepseek-v4.1-flash").input, 0.15);
  assert.equal(PRICING_VERSION, "2026-11-23.1");
});

test("Haiku 5.5 uses the catalogue context tier above 100K prompt tokens", () => {
  const tiered = { input: 0.50, output: 2.50, cacheRead: 0.05, cacheWrite: 0.625 };
  assert.deepEqual(getPricing("anthropic/claude-haiku-5-5", 100001), tiered);
  assert.deepEqual(getPricing("anthropic/claude-haiku-5-5", 100000), {
    input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125,
  });

  // 150K-context worker message: mostly cache reads, as in long sessions.
  const longTokens = { input: 1000, output: 2000, reasoning: 3000, cache: { read: 144000, write: 5000 } };
  assert.equal(getPromptContextTokens(longTokens), 150000);
  assert.equal(calculateCost(longTokens, "anthropic/claude-haiku-5-5"), 0.023325);

  // Below the threshold the same shape keeps base rates.
  const shortTokens = { input: 1000, output: 2000, reasoning: 3000, cache: { read: 44000, write: 5000 } };
  assert.equal(calculateCost(shortTokens, "anthropic/claude-haiku-5-5"), 0.003665);

  // Untiered models ignore context size.
  assert.deepEqual(getPricing("anthropic/claude-sonnet-5-5", 150000), getPricing("anthropic/claude-sonnet-5-5"));
});

test("specific Anthropic IDs win over generic family keys", () => {
  assert.equal(getPricing("anthropic/claude-opus-5-5").input, 4.0);
  assert.equal(getPricing("anthropic/claude-opus-5-5-fast").input, 8.0);
  assert.equal(getPricing("anthropic/claude-opus-4-6").input, 5.0);
  assert.equal(getPricing("anthropic/claude-haiku-4-5").input, 1.0);
  assert.deepEqual(getPricing("anthropic/claude-fable-5-2"), {
    input: 8.0, output: 40.0, cacheRead: 0.20, cacheWrite: 10.0,
  });
  assert.equal(getPricing("anthropic/claude-fable-5-2-fast").output, 80.0);
  assert.deepEqual(getPricing("anthropic/claude-haiku-5-5"), {
    input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125,
  });
  assert.equal(getPricing("anthropic/claude-sonnet-5").output, 10.0);
  assert.deepEqual(getPricing("anthropic/claude-sonnet-5-5"), {
    input: 2.0, output: 10.0, cacheRead: 0.10, cacheWrite: 2.50,
  });
});

test("Sol Pro does not inherit unpublished standard Sol pricing", () => {
  assert.deepEqual(getPricing("gpt-5.6-sol-pro"), {
    input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75,
  });
});

test("price estimates retain exact, fallback, and unknown quality", () => {
  assert.equal(getPricingProvenance("gpt-5.6-terra").quality, "exact_model");
  assert.equal(getPricingProvenance("unlisted-model").quality, "fallback");
  assert.equal(getPricingProvenance("gpt-5.6-sol-pro").quality, "unknown");
  assert.equal(getPricingProvenance("gpt-6.1-sol").quality, "exact_model");
  assert.equal(getPricingProvenance("gpt-6.1-terra").quality, "exact_model");
  assert.equal(getPricingProvenance("gpt-6-sol").quality, "exact_model");
  assert.equal(getPricingProvenance("gpt-6-luna").quality, "exact_model");
});
