// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for informational tool telemetry leaking into OpenCode's
// stderr-backed TUI. Tool titles are unbounded payloads (often full commands),
// so they must go to persistent logs rather than console.error.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createQualityHooks } from "../quality-hooks.mjs";

test("post-tool operation telemetry stays out of the TUI and is safely persisted", async () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-tui-routing-"));
  const trackerPath = join(tempDir, "pattern-tracker-helper.sh");
  const capturePath = join(tempDir, "tracker-args.txt");
  const previousCapture = process.env.AIDEVOPS_TEST_PATTERN_CAPTURE;
  const originalConsoleError = console.error;
  const consoleCalls = [];
  const credential = `ghp_${"a".repeat(36)}`;
  const title = `git commit shellcheck headless-runtime-failure.sh\n${credential}\t${"x".repeat(600)}`;

  writeFileSync(
    trackerPath,
    "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > \"$AIDEVOPS_TEST_PATTERN_CAPTURE\"\n",
  );
  process.env.AIDEVOPS_TEST_PATTERN_CAPTURE = capturePath;
  console.error = (...args) => consoleCalls.push(args);

  try {
    const hooks = createQualityHooks({ scriptsDir: tempDir, logsDir: tempDir });
    await hooks.toolExecuteAfter(
      { tool: "bash", callID: "" },
      { title, output: "", metadata: {} },
    );

    const qualityLog = readFileSync(join(tempDir, "quality-hooks.log"), "utf8");
    const trackerArgs = readFileSync(capturePath, "utf8");
    assert.doesNotMatch(qualityLog, /ghp_|[\r\t]/);
    assert.match(qualityLog, /\[redacted-credential]/);
    assert.match(qualityLog, /Git operation:/);
    assert.match(qualityLog, /Lint run:/);
    assert.doesNotMatch(trackerArgs, /ghp_|[\r\t]/);
    assert.equal(consoleCalls.some((args) => args.join(" ").includes("Git operation detected")), false);
  } finally {
    console.error = originalConsoleError;
    if (previousCapture === undefined) delete process.env.AIDEVOPS_TEST_PATTERN_CAPTURE;
    else process.env.AIDEVOPS_TEST_PATTERN_CAPTURE = previousCapture;
    rmSync(tempDir, { recursive: true, force: true });
  }
});
