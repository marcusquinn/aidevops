// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for informational tool telemetry leaking into OpenCode's
// stderr-backed TUI. Tool titles are unbounded payloads (often full commands),
// so they must go to persistent logs rather than console.error.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const pluginDir = resolve(__dirname, "..");

test("Bash operation telemetry never writes tool titles to the TUI console", () => {
  const src = readFileSync(resolve(pluginDir, "quality-hooks.mjs"), "utf8");
  const tracker = src.match(
    /function trackBashOperation\([\s\S]+?\n}\n\n\/\*\*/,
  )?.[0];

  assert.ok(tracker, "trackBashOperation should remain discoverable for the routing policy test");
  assert.doesNotMatch(
    tracker,
    /console\.(?:error|warn|log)/,
    "informational operation payloads must not be written over OpenCode's TUI",
  );
  assert.match(
    tracker,
    /qualityLog\([^\n]+"INFO", `Git operation: \$\{title}`\)/,
    "Git operation telemetry should remain available in the persistent quality log",
  );
  assert.match(
    tracker,
    /recordGitPattern\(ctx\.scriptsDir, title, outputText\)/,
    "removing TUI output must not disable pattern telemetry",
  );
});
