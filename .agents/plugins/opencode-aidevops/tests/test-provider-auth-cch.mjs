// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Tests for Anthropic OAuth provider CCH billing-header finalisation.
// ---------------------------------------------------------------------------
// Runs under the built-in `node:test` runner. No external deps.
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-provider-auth-cch.mjs

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { transformRequestBody } from "../provider-auth-request.mjs";
import { computeBodyHash } from "../provider-auth-cch.mjs";

function minimalMessagesBody() {
  return JSON.stringify({
    model: "claude-sonnet-4-6",
    messages: [{ role: "user", content: [{ type: "text", text: "Say hi." }] }],
    system: [{ type: "text", text: "You are helpful." }],
    max_tokens: 16,
    stream: true,
  });
}

describe("Anthropic CCH billing header", () => {
  test("replaces the cch placeholder with the xxHash64 body hash", () => {
    const transformed = transformRequestBody(minimalMessagesBody());
    const parsed = JSON.parse(transformed);
    const billingHeader = parsed.system[0].text;
    const match = billingHeader.match(/cch=([0-9a-f]{5});/);

    assert.ok(match, "billing header must contain a 5-char cch value");
    assert.notEqual(match[1], "00000", "placeholder cch value must not be sent to Anthropic");

    const placeholderBody = transformed.replace(/cch=[0-9a-f]{5};/, "cch=00000;");
    assert.equal(
      match[1],
      computeBodyHash(placeholderBody),
      "final cch value must hash the serialized body with the placeholder header",
    );
  });

  test("moves framework system prompts to the first user message", () => {
    const transformed = transformRequestBody(JSON.stringify({
      model: "claude-sonnet-4-6",
      messages: [{ role: "user", content: [{ type: "text", text: "Say hi." }] }],
      system: [
        { type: "text", text: "## aidevops Quality Rules\nUse OpenCode-specific instructions." },
        { type: "text", text: "You are Claude Code, Anthropic's official CLI for Claude." },
      ],
      max_tokens: 16,
      stream: true,
    }));
    const parsed = JSON.parse(transformed);

    assert.equal(parsed.system.length, 2, "only billing and official Claude Code prompt stay in system");
    assert.match(parsed.system[0].text, /^x-anthropic-billing-header:/);
    assert.equal(parsed.system[1].text, "You are Claude Code, Anthropic's official CLI for Claude.");
    assert.match(parsed.messages[0].content[0].text, /aidevops Quality Rules/);
    assert.equal(parsed.messages[0].content[1].text, "Say hi.");
  });
});
