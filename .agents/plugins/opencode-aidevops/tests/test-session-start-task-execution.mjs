// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { buildSessionStartGreetingInstruction } from "../ttsr.mjs";

const instruction = buildSessionStartGreetingInstruction("/missing", () => "");

assert.match(instruction, /greeting is only a required prefix/);
assert.match(instruction, /SAME assistant turn/);
assert.match(instruction, /Never stop after acknowledging/);
assert.match(instruction, /call the appropriate tools immediately/);

console.log("session-start task execution instruction tests passed");
