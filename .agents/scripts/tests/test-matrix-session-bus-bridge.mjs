// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
import assert from "node:assert/strict";
import { parseBusCommand, busArgsFor, relayOutbox } from "../matrix-session-bus-bridge.mjs";

const context = { roomId: "!room:example.org", actorEntityId: "ent_123", redact: true };
for (const [text, type] of [["!sessions", "list"], ["!ask ses_123 hello", "ask"], ["!send ses_123 hi", "send"], ["!bind ses_123", "bind"], ["!unbind", "unbind"], ["!launch title :: task", "launch"], ["!ai hello", "ask"]]) {
  const call = busArgsFor(parseBusCommand(text), context);
  assert.equal(call.args[0], type);
  assert.ok(call.args.includes("chat:matrix:!room:example.org"));
  assert.ok(call.args.includes("ent_123"));
}
assert.equal(parseBusCommand("ordinary message"), null);
assert.ok(busArgsFor(parseBusCommand("!sessions"), context).args.includes("--redact"));
const payload = "--json\n--actor attacker";
const safe = busArgsFor(parseBusCommand(`!ask ses_123 ${payload}`), context);
assert.equal(safe.input, payload);
assert.equal(safe.args.filter((arg) => arg === "--actor").length, 1);
assert.throws(() => busArgsFor(parseBusCommand("!ask --json hello"), context));
assert.throws(() => busArgsFor(parseBusCommand("!bind"), context));

const calls = [];
const runCli = async (args) => {
  calls.push(args);
  return args.includes("--ack") ? "ok" : JSON.stringify([{ id: "msg_1", channel: "!room:example.org", text: "reply" }]);
};
await relayOutbox({ runCli, sendText: async (room, text) => { assert.equal(room, context.roomId); assert.equal(text, "reply"); } });
assert.equal(calls.length, 2);
assert.ok(calls[1].includes("msg_1"));
calls.length = 0;
await relayOutbox({ runCli, sendText: async () => { throw new Error("send failed"); } });
assert.equal(calls.length, 1);
console.log("Matrix session bus bridge tests passed");
