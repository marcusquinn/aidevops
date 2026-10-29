// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { annotateTurnTimes, annotateTurnTimesSafely } from "../turn-time-annotation.mjs";

const created = Date.parse("2026-10-29T02:37:59.123Z");
const user = (time = created) => ({ info: { role: "user", sessionID: "root", time: { created: time } }, parts: [{ type: "text", text: "hello" }] });
const client = { session: { get: async ({ path }) => ({ data: { id: path.id, parentID: path.id === "child" ? "root" : undefined } }) } };

test("fixed receive times prepend synthetic UTC minute parts and stay byte-identical", async () => {
  const output = { messages: [user(), user(created + 3 * 60 * 60 * 1000)] };
  const originalParts = output.messages[0].parts;
  await annotateTurnTimes({}, output, { client });
  assert.deepEqual(output.messages[0].parts[0], { type: "text", text: "[turn received 2026-10-29T02:37Z]", synthetic: true });
  assert.equal(output.messages[1].parts[0].text, "[turn received 2026-10-29T05:37Z]");
  assert.deepEqual(originalParts, [{ type: "text", text: "hello" }]);
  const once = JSON.stringify(output);
  await annotateTurnTimes({}, output, { client });
  assert.equal(JSON.stringify(output), once);
  const fresh = { messages: [user()] };
  await annotateTurnTimes({}, fresh, { client });
  assert.deepEqual(fresh.messages[0], output.messages[0]);
});

test("host-generated compaction anchors stay unchanged alongside interactive turns", async () => {
  const anchor = user();
  anchor.parts.push({ type: "compaction", auto: true });
  const before = structuredClone(anchor);
  const output = { messages: [anchor, user()] };
  await annotateTurnTimes({}, output, { client });
  assert.deepEqual(anchor, before);
  assert.equal(output.messages[1].parts[0].text, "[turn received 2026-10-29T02:37Z]");
});

test("assistant, missing/non-finite/out-of-range dates, and malformed messages stay unchanged", async () => {
  const output = { messages: [null, {}, { ...user(), info: { role: "assistant", time: { created } } }, ...[null, "123", NaN, Infinity, 1e20].map(user), { info: { role: "user" } }] };
  const before = structuredClone(output);
  await annotateTurnTimes({ sessionID: "root" }, output, { client });
  assert.deepEqual(output, before);
  await annotateTurnTimes({}, {}, { client });
});

test("headless, opt-out, child, and unverified sessions are unchanged", async () => {
  for (const options of [
    { client, isHeadless: () => true },
    { client: { session: { get: async () => ({ data: { id: "root", parentID: "parent" } }) } } },
    {},
  ]) {
    const output = { messages: [user()] };
    const before = structuredClone(output);
    await annotateTurnTimes({}, output, options);
    assert.deepEqual(output, before);
  }
  const previous = process.env.AIDEVOPS_TURN_TIME_ANNOTATION;
  try {
    process.env.AIDEVOPS_TURN_TIME_ANNOTATION = "0";
    const output = { messages: [user()] };
    await annotateTurnTimes({}, output, { client: { session: { get: () => assert.fail("opt-out must not look up sessions") } } });
    assert.deepEqual(output.messages, [user()]);
  } finally {
    if (previous === undefined) delete process.env.AIDEVOPS_TURN_TIME_ANNOTATION;
    else process.env.AIDEVOPS_TURN_TIME_ANNOTATION = previous;
  }
  const child = { messages: [user()] };
  await annotateTurnTimes({ sessionID: "child" }, child, { client });
  assert.deepEqual(child.messages, [user()]);
});

test("plugin catches annotation failures before continuing later transforms", async () => {
  const output = { messages: [user()] };
  const options = { client: { session: { get: async () => { throw new Error("unavailable"); } } } };
  await assert.rejects(annotateTurnTimes({}, output, options), /unavailable/);
  const logs = [];
  await annotateTurnTimesSafely({}, output, options, (...args) => logs.push(args));
  assert.deepEqual(logs, [["WARN", "[turn-time-annotation] Unexpected error: unavailable"]]);
  assert.deepEqual(output.messages, [user()]);
  const source = readFileSync(new URL("../index.mjs", import.meta.url), "utf8");
  assert.match(source, /await compactionInputReplay\.inject\(input, output\);\s+await annotateTurnTimesSafely\(input, output, \{ client, isHeadless \}, qualityLog\);/);
});
