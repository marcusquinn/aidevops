// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import { test } from "node:test";
import assert from "node:assert/strict";
import { createInstructionReminderCompactor, extractInstructionSources } from "../instruction-reminders.mjs";

const GUIDE = "# Guide\nRule one.\nRule two.\n";
const LOADED = "/home/user/.aidevops/agents/AGENTS.md";
const REPO_COPY = "/repo/.agents/AGENTS.md";
const OTHER = "/repo/.agents/tools/AGENTS.md";

function files(map) {
  return (path) => {
    if (!(path in map)) throw new Error(`ENOENT: ${path}`);
    return map[path];
  };
}

// Mirrors OpenCode 1.18 Read output: body, then a reminder with each loaded document.
function readOutput(paths, contents) {
  const documents = paths.map((path) => `Instructions from: ${path}\n${contents[path]}`);
  return `<path>/repo/.agents/x.md</path>\n<content>\n1: hi\n</content>\n\n<system-reminder>\n${documents.join("\n\n")}\n</system-reminder>`;
}

test("extracts instruction sources from separate and joined system strings", () => {
  const sources = extractInstructionSources([
    `Instructions from: ${LOADED}\n${GUIDE}`,
    `prefix\nInstructions from: /a/AGENTS.md\nbody\n\nInstructions from: /b/AGENTS.md\nbody`,
    42,
  ]);
  assert.deepEqual([...sources], [LOADED, "/a/AGENTS.md", "/b/AGENTS.md"]);
});

test("replaces only a byte-identical reminder with a pointer and keeps metadata", () => {
  const contents = { [LOADED]: GUIDE, [REPO_COPY]: GUIDE, [OTHER]: "# Tools only\n" };
  const compactor = createInstructionReminderCompactor({ readFile: files(contents) });
  compactor.rememberSystem("s1", [`Instructions from: ${LOADED}\n${GUIDE}`]);
  const output = { output: readOutput([REPO_COPY, OTHER], contents), metadata: { loaded: [REPO_COPY, OTHER] } };

  assert.equal(compactor.compactReadOutput({ tool: "read", sessionID: "s1" }, output), 1);
  assert.ok(output.output.includes(`Instructions from: ${REPO_COPY}\nThe complete instruction body is byte-identical to the already loaded instructions from: ${LOADED}.`));
  assert.ok(!output.output.includes(`Instructions from: ${REPO_COPY}\n${GUIDE}`));
  assert.ok(output.output.includes(`Instructions from: ${OTHER}\n# Tools only\n`), "different guidance stays verbatim");
  assert.ok(output.output.endsWith("</system-reminder>"));
  assert.deepEqual(output.metadata.loaded, [REPO_COPY, OTHER], "host dedupe metadata is untouched");
});

test("fails open for other tools, unknown sessions, differing bodies and unreadable files", () => {
  const contents = { [LOADED]: GUIDE, [REPO_COPY]: `${GUIDE}local change\n` };
  const compactor = createInstructionReminderCompactor({ readFile: files(contents) });
  compactor.rememberSystem("s1", [`Instructions from: ${LOADED}\n${GUIDE}`]);
  const original = readOutput([REPO_COPY], contents);
  const cases = [
    [{ tool: "bash", sessionID: "s1" }, { output: original, metadata: { loaded: [REPO_COPY] } }],
    [{ tool: "read", sessionID: "other" }, { output: original, metadata: { loaded: [REPO_COPY] } }],
    [{ tool: "read", sessionID: "s1" }, { output: original, metadata: { loaded: [REPO_COPY] } }],
    [{ tool: "read", sessionID: "s1" }, { output: original, metadata: { loaded: ["/missing/AGENTS.md"] } }],
    [{ tool: "read", sessionID: "s1" }, { output: original, metadata: {} }],
  ];
  for (const [input, output] of cases) {
    assert.equal(compactor.compactReadOutput(input, output), 0);
    assert.equal(output.output, original);
  }
});

test("the same input produces identical bytes for stable prompt caching", () => {
  const contents = { [LOADED]: GUIDE, [REPO_COPY]: GUIDE };
  const compactor = createInstructionReminderCompactor({ readFile: files(contents) });
  compactor.rememberSystem("s1", [`Instructions from: ${LOADED}\n${GUIDE}`]);
  const first = { output: readOutput([REPO_COPY], contents), metadata: { loaded: [REPO_COPY] } };
  const second = { output: readOutput([REPO_COPY], contents), metadata: { loaded: [REPO_COPY] } };
  compactor.compactReadOutput({ tool: "read", sessionID: "s1" }, first);
  compactor.compactReadOutput({ tool: "read", sessionID: "s1" }, second);
  assert.equal(first.output, second.output);
});
