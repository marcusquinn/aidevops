// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { checkRedactedEdit } from "../redacted-edit-guard.mjs";
import { createQualityHooks } from "../quality-hooks.mjs";

const TOKEN = "[redacted-credential]";
const PEM_TOKEN = "[redacted-private-key]";

function scratch(t, content) {
  const directory = mkdtempSync(join(tmpdir(), "aidevops-redacted-edit-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const filePath = join(directory, "sample.txt");
  writeFileSync(filePath, content);
  return { directory, filePath };
}

test("Read scrubbing followed by a neighbouring Edit fails closed before mutation", async (t) => {
  // Construct a harmless hyphenated word without putting a credential-shaped
  // literal in the test source. This intentionally exercises the real scrubber.
  const original = `# before ${["sk", "ordinary-hyphenated-word"].join("-")} after\n`;
  const { directory, filePath } = scratch(t, original);
  const scriptsDir = fileURLToPath(new URL("../../../scripts/", import.meta.url));
  const hooks = createQualityHooks({ scriptsDir, logsDir: directory, repositoryDir: directory });
  const readOutput = { output: original, metadata: {} };
  await hooks.toolExecuteAfter({ tool: "read", callID: "" }, readOutput);
  assert.equal(readOutput.output, `# before ${TOKEN} after\n`);
  const args = { filePath, oldString: readOutput.output, newString: readOutput.output.replace("before", "updated") };
  await assert.rejects(hooks.toolExecuteBefore({ tool: "edit", callID: "" }, { args }), /Edit blocked: display-redaction/);
  assert.equal(readFileSync(filePath, "utf8"), original);
  assert.equal(args.oldString, readOutput.output);
  assert.equal(args.newString, readOutput.output.replace("before", "updated"));
});

test("literal placeholders can be preserved or removed, but not added", (t) => {
  const original = `before ${TOKEN} ${PEM_TOKEN} after`;
  const { filePath } = scratch(t, original);
  for (const newString of [original.replace("before", "updated"), "updated"]) {
    assert.doesNotThrow(() => checkRedactedEdit("Edit", { filePath, oldString: original, newString }));
  }
  assert.throws(() => checkRedactedEdit("edit", { filePath, oldString: original, newString: `${original} ${TOKEN}` }), /Edit blocked/);
  assert.throws(() => checkRedactedEdit("edit", { filePath, oldString: "before", newString: TOKEN }), /Edit blocked/);
});

test("a placeholder elsewhere in the file does not authorize a fuzzy edit", (t) => {
  const { filePath } = scratch(t, `documented ${TOKEN}\nbefore original after\n`);
  assert.throws(() => checkRedactedEdit("edit", {
    filePath, oldString: `before ${TOKEN} after`, newString: `updated ${TOKEN} after`,
  }), /Edit blocked/);
});

test("private-key redaction, aliases, relative paths and unreadable files fail safely", (t) => {
  const { directory, filePath } = scratch(t, `before ${PEM_TOKEN} after`);
  assert.doesNotThrow(() => checkRedactedEdit("functions/edit_file", {
    path: "sample.txt", old_string: `before ${PEM_TOKEN} after`, new_string: `updated ${PEM_TOKEN} after`,
  }, directory));
  for (const path of [filePath, join(directory, "missing.txt")]) {
    assert.throws(() => checkRedactedEdit("functions.edit", {
      file_path: path, old_string: `different ${PEM_TOKEN}`, new_string: PEM_TOKEN,
    }), /Edit blocked/);
  }
});

test("ordinary edits and non-edit tools retain their existing behavior", () => {
  assert.doesNotThrow(() => checkRedactedEdit("edit", { filePath: "missing", oldString: "before", newString: "after" }));
  assert.doesNotThrow(() => checkRedactedEdit("read", { oldString: TOKEN, newString: TOKEN }));
  assert.throws(() => checkRedactedEdit("edit", { oldString: "", newString: TOKEN }), /Edit blocked/);
});
