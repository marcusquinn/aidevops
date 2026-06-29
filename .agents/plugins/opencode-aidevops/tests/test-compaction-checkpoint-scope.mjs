// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage: compaction checkpoints must be scoped to the active
// repository. A legacy global checkpoint, or a scoped checkpoint for a sibling
// repository, must not be injected into the current session summary.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

function initRepo(repoDir) {
  mkdirSync(repoDir, { recursive: true });
  execFileSync("git", ["init", "-q"], { cwd: repoDir });
  return repoDir;
}

function scopedCheckpointPath(workspaceDir, repoDir) {
  const root = execFileSync("git", ["rev-parse", "--show-toplevel"], {
    cwd: repoDir,
    encoding: "utf8",
  }).trim();
  const key = createHash("sha256").update(root).digest("hex").slice(0, 16);
  return resolve(workspaceDir, "tmp", "session-checkpoints", `repo-${key}.md`);
}

test("compaction injects only the active repository checkpoint", async () => {
  const tempDir = mkdtempSync(resolve(tmpdir(), "aidevops-compaction-scope-"));

  try {
    const workspaceDir = resolve(tempDir, "workspace");
    const scriptsDir = resolve(tempDir, "scripts");
    const targetRepo = initRepo(resolve(tempDir, "target-repo"));
    const otherRepo = initRepo(resolve(tempDir, "other-repo"));

    mkdirSync(resolve(workspaceDir, "tmp", "session-checkpoints"), { recursive: true });
    mkdirSync(scriptsDir, { recursive: true });

    writeFileSync(
      resolve(workspaceDir, "tmp", "session-checkpoint.md"),
      "UNRELATED_LEGACY_CHECKPOINT_STATE\n",
      "utf8",
    );
    writeFileSync(
      scopedCheckpointPath(workspaceDir, otherRepo),
      "UNRELATED_SIBLING_CHECKPOINT_STATE\n",
      "utf8",
    );
    writeFileSync(
      scopedCheckpointPath(workspaceDir, targetRepo),
      "TARGET_REPO_CHECKPOINT_STATE\n",
      "utf8",
    );

    const { compactingHook } = await import(resolve(__dirname, "..", "compaction.mjs"));
    const output = { context: [] };

    await compactingHook({ workspaceDir, scriptsDir }, { sessionID: "test" }, output, targetRepo);

    const payload = output.context.join("\n");
    assert.match(payload, /TARGET_REPO_CHECKPOINT_STATE/);
    assert.doesNotMatch(payload, /UNRELATED_LEGACY_CHECKPOINT_STATE/);
    assert.doesNotMatch(payload, /UNRELATED_SIBLING_CHECKPOINT_STATE/);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});
