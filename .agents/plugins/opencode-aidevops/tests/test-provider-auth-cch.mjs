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
import { computeBodyHash, CCH_PLACEHOLDER } from "../provider-auth-cch.mjs";

function minimalMessagesBody() {
  return JSON.stringify({
    model: "claude-sonnet-4-6",
    messages: [{ role: "user", content: [{ type: "text", text: "Say hi." }] }],
    system: [{ type: "text", text: "You are helpful." }],
    max_tokens: 16,
    stream: true,
  });
}

const EPHEMERAL = Object.freeze({ type: "ephemeral" });
const HEADER_PREFIX = '"system":[{"type":"text","text":"x-anthropic-billing-header:';

/** Rebuild the hash input: placeholder at the billing header position only. */
function headerPlaceholderBody(transformed) {
  const headerStart = transformed.indexOf(HEADER_PREFIX);
  assert.ok(headerStart >= 0, "billing header must be the first system block");
  const cchIndex = transformed.indexOf("cch=", headerStart);
  return transformed.slice(0, cchIndex) + CCH_PLACEHOLDER + transformed.slice(cchIndex + CCH_PLACEHOLDER.length);
}

function countCacheMarkers(parsed) {
  const blocks = [
    ...(parsed.tools ?? []),
    ...(parsed.system ?? []),
    ...parsed.messages.flatMap((message) => (Array.isArray(message.content) ? message.content : [])),
  ];
  return blocks.filter((block) => block.cache_control).length;
}

function historyWithPlaceholderBody() {
  return JSON.stringify({
    model: "claude-opus-4-6",
    messages: [
      { role: "user", content: [{ type: "text", text: "Read the capture." }] },
      { role: "assistant", content: [{ type: "tool_use", id: "toolu_1", name: "read", input: { filePath: "capture.txt" } }] },
      {
        role: "user",
        content: [{
          type: "tool_result",
          tool_use_id: "toolu_1",
          content: `captured: x-anthropic-billing-header: cc_version=2.1.92.abc; cc_entrypoint=cli; ${CCH_PLACEHOLDER}`,
        }],
      },
    ],
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

    const placeholderBody = transformed.replace(/cch=[0-9a-f]{5};/, CCH_PLACEHOLDER);
    assert.equal(
      match[1],
      computeBodyHash(placeholderBody),
      "final cch value must hash the serialized body with the placeholder header",
    );
  });

  test("signs only the header when history already contains the placeholder text (GH#32444)", () => {
    const input = historyWithPlaceholderBody();
    const first = transformRequestBody(input);
    const second = transformRequestBody(input);
    const toolResult = (body) => JSON.parse(body).messages[2].content[0].content;

    assert.ok(toolResult(first).endsWith(CCH_PLACEHOLDER), "history bytes must not be signed");
    assert.equal(toolResult(first), toolResult(second));
    assert.equal(
      first.slice(0, first.indexOf(HEADER_PREFIX)),
      second.slice(0, second.indexOf(HEADER_PREFIX)),
      "serialized messages must be byte-identical across requests so the prompt cache can hit",
    );

    const header = JSON.parse(first).system[0].text;
    const match = header.match(/cch=([0-9a-f]{5});$/);
    assert.ok(match, "billing header must end with a signed 5-char cch value");
    assert.ok(!header.endsWith(CCH_PLACEHOLDER), "billing header must not ship unsigned");
    assert.ok(!header.includes("AIDEVOPS_CCH_"), "sentinel must never reach the wire");
    assert.equal(match[1], computeBodyHash(headerPlaceholderBody(first)));
  });

  test("keeps a cache breakpoint on redistributed system text (GH#32444)", () => {
    const transformed = transformRequestBody(JSON.stringify({
      model: "claude-sonnet-4-6",
      messages: [{ role: "user", content: [{ type: "text", text: "Say hi.", cache_control: EPHEMERAL }] }],
      system: [
        { type: "text", text: "Framework prompt.", cache_control: EPHEMERAL },
        { type: "text", text: "Project instructions.", cache_control: EPHEMERAL },
      ],
      max_tokens: 16,
      stream: true,
    }));
    const parsed = JSON.parse(transformed);

    assert.equal(parsed.system.length, 1, "only the billing header stays in system");
    assert.equal(parsed.messages[0].content[0].text, "Framework prompt.\n\nProject instructions.");
    assert.deepEqual(parsed.messages[0].content[0].cache_control, EPHEMERAL);
    assert.deepEqual(parsed.messages[0].content[1].cache_control, EPHEMERAL);
    assert.equal(countCacheMarkers(parsed), 2);
  });

  test("never exceeds four cache breakpoints when carrying the system marker", () => {
    const transformed = transformRequestBody(JSON.stringify({
      model: "claude-sonnet-4-6",
      messages: [
        { role: "user", content: [{ type: "text", text: "One.", cache_control: EPHEMERAL }] },
        { role: "assistant", content: [{ type: "text", text: "Two.", cache_control: EPHEMERAL }] },
        { role: "user", content: [{ type: "text", text: "Three.", cache_control: EPHEMERAL }] },
      ],
      system: [{ type: "text", text: "Framework prompt.", cache_control: EPHEMERAL }],
      tools: [{ name: "read", input_schema: { type: "object", properties: {} }, cache_control: EPHEMERAL }],
      max_tokens: 16,
      stream: true,
    }));
    const parsed = JSON.parse(transformed);

    assert.equal(parsed.messages[0].content[0].text, "Framework prompt.");
    assert.equal(parsed.messages[0].content[0].cache_control, undefined);
    assert.equal(countCacheMarkers(parsed), 4);
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

  test("drops unsupported adaptive metadata while preserving effort and tool calls", () => {
    const transformed = transformRequestBody(JSON.stringify({
      model: "claude-opus-5-5",
      messages: [{ role: "user", content: [{ type: "text", text: "Read README.md." }] }],
      thinking: { type: "adaptive", block_binding: "upstream-metadata" },
      output_config: { effort: "medium" },
      tools: [{ name: "read", input_schema: { type: "object", properties: {} } }],
      max_tokens: 64,
      stream: true,
    }));
    const parsed = JSON.parse(transformed);

    assert.deepEqual(parsed.thinking, { type: "adaptive" });
    assert.deepEqual(parsed.output_config, { effort: "medium" });
    assert.equal(parsed.tools[0].name, "Read");
    assert.ok(parsed.tools[0].input_schema.properties.agent__intent);
    assert.ok(!transformed.includes("block_binding"));
  });
});
