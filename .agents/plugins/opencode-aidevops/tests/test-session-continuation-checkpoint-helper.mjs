// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { createSessionContinuationGuard } from "../session-continuation-guard.mjs";

const fixtureDir = mkdtempSync(join(tmpdir(), "aidevops-continuation-"));

try {
  const repository = join(fixtureDir, "repository");
  const checkpointHelper = join(fixtureDir, "checkpoint-helper.sh");
  mkdirSync(repository);
  writeFileSync(checkpointHelper, `#!/usr/bin/env bash
if [[ "$1" == "recovery-status" && "$2" == "--json" ]]; then
  printf '%s\\n' '{"status":"recovering","unresolved":true,"remaining":"Verify checkpoint recovery"}'
fi
`, { mode: 0o644 });

  const guard = createSessionContinuationGuard({
    repository,
    checkpointHelper: relative(process.cwd(), checkpointHelper),
  });
  const state = guard.getState({ sessionID: "non-executable-helper" });

  assert.equal(state.recovery?.status, "recovering");
  assert.equal(state.recovery?.remaining, "Verify checkpoint recovery");

  for (const [name, payload] of [
    ["null", null],
    ["array", [{ status: "recovering" }]],
    ["primitive", "recovering"],
    ["inactive", { status: "none" }],
  ]) {
    const ignoredGuard = createSessionContinuationGuard({
      repository,
      checkpointAdapter: { load: () => payload },
    });
    const ignoredState = ignoredGuard.getState({ sessionID: `ignored-${name}` });
    assert.equal(ignoredState.recovery, null, `${name} checkpoint payload should be ignored`);
  }
} finally {
  rmSync(fixtureDir, { recursive: true, force: true });
}

console.log("session continuation checkpoint helper tests passed");
