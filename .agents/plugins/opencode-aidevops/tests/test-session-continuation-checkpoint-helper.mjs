// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSessionContinuationGuard } from "../session-continuation-guard.mjs";

const fixtureDir = mkdtempSync(join(tmpdir(), "aidevops-continuation-"));

try {
  const checkpointHelper = join(fixtureDir, "checkpoint-helper.sh");
  writeFileSync(checkpointHelper, `#!/usr/bin/env bash
if [[ "$1" == "recovery-status" && "$2" == "--json" ]]; then
  printf '%s\\n' '{"status":"recovering","unresolved":true,"remaining":"Verify checkpoint recovery"}'
fi
`, { mode: 0o644 });

  const guard = createSessionContinuationGuard({ repository: fixtureDir, checkpointHelper: "checkpoint-helper.sh" });
  const state = guard.getState({ sessionID: "non-executable-helper" });

  assert.equal(state.recovery?.status, "recovering");
  assert.equal(state.recovery?.remaining, "Verify checkpoint recovery");
} finally {
  rmSync(fixtureDir, { recursive: true, force: true });
}

console.log("session continuation checkpoint helper tests passed");
