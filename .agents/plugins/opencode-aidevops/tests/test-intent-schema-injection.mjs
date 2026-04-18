// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Test suite for injectIntentParameter (t2188 / GH#19649)
// ---------------------------------------------------------------------------
// Runs under the built-in `node:test` runner. No external deps.
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-intent-schema-injection.mjs
//
// Background
//   Anthropic's Messages API validates tool-call arguments against each
//   tool's declared input_schema and strips unknown properties before the
//   tool_use block reaches the client. ttsr.mjs injects a system-prompt
//   instruction telling the LLM to include `agent__intent` on every tool
//   call, but without a corresponding schema property the field is dropped
//   — which is why observability.tool_calls.intent went from thousands/day
//   of coverage on OpenAI (call_*) traffic to zero on recent Anthropic
//   (toolu_*) traffic after direct-API transit landed.
//
// Invariants under test
//   1. Every well-formed object-typed tool schema gains `agent__intent`.
//   2. The injection is additive: it never modifies `required`, so the
//      LLM may legitimately omit the field (zero-cost on skip).
//   3. Tools without a standard `type: "object"` schema are untouched.
//   4. Tools that already declare `agent__intent` are untouched (future
//      tool authors may legitimately reserve the name).
//   5. Input is not mutated in place — the transform is pure.
// ---------------------------------------------------------------------------

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { injectIntentParameter } from "../provider-auth-request.mjs";

const INTENT_FIELD = "agent__intent";

// ---------------------------------------------------------------------------
// Happy path: typical object-schema tools get the intent property injected
// ---------------------------------------------------------------------------

describe("injectIntentParameter — standard object schemas", () => {
  test("adds agent__intent to a tool with an object schema", () => {
    const tools = [{
      name: "Read",
      description: "Read a file",
      input_schema: {
        type: "object",
        properties: { filePath: { type: "string" } },
        required: ["filePath"],
      },
    }];
    const out = injectIntentParameter(tools);
    assert.ok(
      Object.prototype.hasOwnProperty.call(out[0].input_schema.properties, INTENT_FIELD),
      "intent property was not injected",
    );
    assert.equal(out[0].input_schema.properties[INTENT_FIELD].type, "string");
    assert.ok(
      typeof out[0].input_schema.properties[INTENT_FIELD].description === "string" &&
        out[0].input_schema.properties[INTENT_FIELD].description.length > 0,
      "intent property must carry a non-empty description",
    );
  });

  test("preserves all pre-existing properties", () => {
    const tools = [{
      name: "Edit",
      input_schema: {
        type: "object",
        properties: {
          filePath: { type: "string" },
          oldString: { type: "string" },
          newString: { type: "string" },
        },
        required: ["filePath", "oldString", "newString"],
      },
    }];
    const out = injectIntentParameter(tools);
    const props = out[0].input_schema.properties;
    assert.ok(props.filePath, "filePath preserved");
    assert.ok(props.oldString, "oldString preserved");
    assert.ok(props.newString, "newString preserved");
    assert.ok(props[INTENT_FIELD], "intent added");
  });

  test("does NOT add agent__intent to required array", () => {
    const tools = [{
      name: "Read",
      input_schema: {
        type: "object",
        properties: { filePath: { type: "string" } },
        required: ["filePath"],
      },
    }];
    const out = injectIntentParameter(tools);
    assert.deepEqual(out[0].input_schema.required, ["filePath"],
      "required array must remain untouched");
  });

  test("handles schemas without a pre-existing properties object", () => {
    const tools = [{
      name: "TodoWrite",
      input_schema: { type: "object" }, // no properties, no required
    }];
    const out = injectIntentParameter(tools);
    assert.ok(out[0].input_schema.properties, "properties now exists");
    assert.ok(
      Object.prototype.hasOwnProperty.call(out[0].input_schema.properties, INTENT_FIELD),
      "intent property was injected onto an empty-properties schema",
    );
  });

  test("handles schemas without a required array", () => {
    const tools = [{
      name: "Ls",
      input_schema: {
        type: "object",
        properties: { path: { type: "string" } },
        // no `required`
      },
    }];
    const out = injectIntentParameter(tools);
    // The transform must not invent a required array.
    assert.equal(out[0].input_schema.required, undefined,
      "required must remain absent when the source schema omitted it");
  });
});

// ---------------------------------------------------------------------------
// Skip conditions: non-object schemas and pre-existing intent
// ---------------------------------------------------------------------------

describe("injectIntentParameter — skip conditions", () => {
  test("leaves a tool without input_schema untouched", () => {
    const tools = [{ name: "NoSchemaTool" }];
    const out = injectIntentParameter(tools);
    assert.deepEqual(out[0], { name: "NoSchemaTool" });
  });

  test("leaves a tool with a null input_schema untouched", () => {
    const tools = [{ name: "NullSchemaTool", input_schema: null }];
    const out = injectIntentParameter(tools);
    assert.equal(out[0].input_schema, null);
  });

  test("leaves a tool with a non-object type schema untouched", () => {
    // Degenerate but legal JSON-Schema — we must not assume `type:object`.
    const schema = { type: "string" };
    const tools = [{ name: "OddTool", input_schema: schema }];
    const out = injectIntentParameter(tools);
    assert.equal(out[0].input_schema, schema,
      "non-object schemas must pass through by reference");
  });

  test("does not overwrite an existing agent__intent property", () => {
    const existingIntentShape = {
      type: "number",
      description: "a tool that legitimately reserves this name",
    };
    const tools = [{
      name: "ReservedNameTool",
      input_schema: {
        type: "object",
        properties: { [INTENT_FIELD]: existingIntentShape },
      },
    }];
    const out = injectIntentParameter(tools);
    assert.deepEqual(out[0].input_schema.properties[INTENT_FIELD], existingIntentShape,
      "existing intent property must not be overwritten");
  });
});

// ---------------------------------------------------------------------------
// Purity: the transform must not mutate its inputs
// ---------------------------------------------------------------------------

describe("injectIntentParameter — purity", () => {
  test("does not mutate the input tool array", () => {
    const tools = [{
      name: "Read",
      input_schema: {
        type: "object",
        properties: { filePath: { type: "string" } },
        required: ["filePath"],
      },
    }];
    const snapshotBefore = JSON.stringify(tools);
    injectIntentParameter(tools);
    assert.equal(JSON.stringify(tools), snapshotBefore,
      "input tools must be unchanged after the transform");
  });

  test("does not share the inner schema object with the input", () => {
    const tools = [{
      name: "Read",
      input_schema: {
        type: "object",
        properties: { filePath: { type: "string" } },
      },
    }];
    const out = injectIntentParameter(tools);
    assert.notEqual(out[0].input_schema, tools[0].input_schema,
      "the output input_schema must be a fresh object");
    assert.notEqual(out[0].input_schema.properties, tools[0].input_schema.properties,
      "the output properties must be a fresh object");
  });
});

// ---------------------------------------------------------------------------
// Mixed-batch: verify independent decisions across multiple tools in one call
// ---------------------------------------------------------------------------

describe("injectIntentParameter — mixed batches", () => {
  test("processes a heterogeneous tool array correctly", () => {
    const tools = [
      // Standard — should gain intent
      {
        name: "Read",
        input_schema: {
          type: "object",
          properties: { filePath: { type: "string" } },
        },
      },
      // No schema — should pass through
      { name: "NoSchemaTool" },
      // Already has intent — should not be overwritten
      {
        name: "ReservedTool",
        input_schema: {
          type: "object",
          properties: { [INTENT_FIELD]: { type: "boolean" } },
        },
      },
      // Non-object schema — should pass through
      {
        name: "StringTool",
        input_schema: { type: "string" },
      },
    ];
    const out = injectIntentParameter(tools);
    assert.equal(out.length, 4);
    assert.ok(out[0].input_schema.properties[INTENT_FIELD],
      "standard tool got intent");
    assert.equal(out[1].input_schema, undefined,
      "schemaless tool untouched");
    assert.equal(out[2].input_schema.properties[INTENT_FIELD].type, "boolean",
      "reserved tool retained its original intent shape");
    assert.equal(out[3].input_schema.type, "string",
      "non-object tool untouched");
  });
});
