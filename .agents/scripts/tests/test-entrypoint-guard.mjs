// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isDirectEntrypoint } from "../entrypoint-guard.mjs";

const scriptsDir = fileURLToPath(new URL("..", import.meta.url));

function withLinkedScriptsDir(callback) {
  const parent = process.env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  const directory = mkdtempSync(join(parent, "entrypoint-guard-test-"));
  try {
    // Mirrors ~/.aidevops/agents -> runtime-bundles/<id>/agents (GH#35206).
    const linkedScripts = join(directory, "scripts");
    symlinkSync(scriptsDir, linkedScripts);
    return callback(linkedScripts, directory);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test("isDirectEntrypoint resolves symlinked argv paths and rejects other or missing paths", () => {
  withLinkedScriptsDir((linkedScripts) => {
    const moduleUrl = pathToFileURL(join(scriptsDir, "entrypoint-guard.mjs")).href;
    assert.equal(isDirectEntrypoint(moduleUrl, join(linkedScripts, "entrypoint-guard.mjs")), true);
    assert.equal(isDirectEntrypoint(moduleUrl, join(linkedScripts, "runtime-events.mjs")), false);
    assert.equal(isDirectEntrypoint(moduleUrl, join(linkedScripts, "missing.mjs")), false);
    assert.equal(isDirectEntrypoint(moduleUrl, undefined), false);
  });
});

test("retention and runtime-event CLIs run through a symlinked scripts directory", () => {
  withLinkedScriptsDir((linkedScripts, directory) => {
    const inventory = spawnSync(process.execPath, [
      join(linkedScripts, "runtime-events-retention.mjs"),
      "inventory", "--db", join(directory, "absent.db"),
    ], { encoding: "utf8" });
    assert.equal(inventory.status, 0, inventory.stderr);
    assert.equal(JSON.parse(inventory.stdout).total_bytes, 0);

    const usage = spawnSync(process.execPath, [join(linkedScripts, "runtime-events.mjs"), "--help"], {
      encoding: "utf8",
    });
    assert.match(`${usage.stdout}${usage.stderr}`, /Usage: runtime-events\.mjs/);
  });
});
