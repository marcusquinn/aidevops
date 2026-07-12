// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { buildSessionStartGreetingInstruction } from "../ttsr.mjs";

const instruction = buildSessionStartGreetingInstruction("/missing", () => "");

assert.match(instruction, /greeting is only a required prefix/);
assert.match(instruction, /SAME assistant turn/);
assert.match(instruction, /Tool calls may precede it/);
assert.match(instruction, /Never emit a greeting-only response/);
assert.match(instruction, /Call the appropriate tools immediately, before visible text if necessary/);
assert.match(instruction, /Do not claim that tool access is unavailable without first attempting/);
assert.doesNotMatch(instruction, /before tool calls, status updates/);

console.log("session-start task execution instruction tests passed");
