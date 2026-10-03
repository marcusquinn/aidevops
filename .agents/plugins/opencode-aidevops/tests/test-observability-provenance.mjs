// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { requestProvenance, runtimeProvenance } from "../observability-provenance.mjs";

test("request provenance prefers supplied runtime identity", () => {
  const previous = process.env.OPENCODE_VERSION;
  process.env.OPENCODE_VERSION = "1.0.0";
  try {
    for (const adapter of ["opencode-v1", "opencode-v2"]) {
      const row = requestProvenance({}, {}, {}, {
        runtimeVersion: "2.0.3",
        adapterVersion: `${adapter}@3.37.7`,
      });
      assert.equal(row.runtime_version, "2.0.3");
      assert.equal(row.adapter_version, `${adapter}@3.37.7`);
    }
  } finally {
    if (previous === undefined) delete process.env.OPENCODE_VERSION;
    else process.env.OPENCODE_VERSION = previous;
  }
});

test("request provenance falls back to environment or null", () => {
  const previous = process.env.OPENCODE_VERSION;
  try {
    process.env.OPENCODE_VERSION = "1.18.32";
    assert.equal(requestProvenance({}, {}, {}).runtime_version, "1.18.32");
    delete process.env.OPENCODE_VERSION;
    const row = requestProvenance({}, {}, {}, { runtimeVersion: null, adapterVersion: null });
    assert.equal(row.runtime_version, null);
    assert.equal(row.adapter_version, null);
  } finally {
    if (previous === undefined) delete process.env.OPENCODE_VERSION;
    else process.env.OPENCODE_VERSION = previous;
  }
});

test("runtime identity normalizes adapter and framework versions", () => {
  assert.deepEqual(runtimeProvenance({
    aidevopsVersion: " v3.37.7 ", runtimeVersion: " 1.18.32 ", adapterId: " opencode-v1 ",
  }), {
    aidevopsVersion: "3.37.7", runtimeVersion: "1.18.32", adapterVersion: "opencode-v1@3.37.7",
  });
  assert.equal(runtimeProvenance({ aidevopsVersion: "unknown", adapterId: "opencode-v1" }).adapterVersion, null);
  assert.equal(runtimeProvenance({ aidevopsVersion: "3.37.7", adapterId: " " }).adapterVersion, null);
});

test("observability persists supplied identities and missing detection stays nullable", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-provenance-"));
  const previousDb = process.env.AIDEVOPS_OBS_DB_OVERRIDE;
  const previousVersion = process.env.OPENCODE_VERSION;
  process.env.AIDEVOPS_OBS_DB_OVERRIDE = join(root, "llm-requests.db");
  delete process.env.OPENCODE_VERSION;
  const observability = await import(`../observability.mjs?provenance=${Date.now()}`);
  const sqlite = await import("../../../scripts/sqlite-process.mjs");
  try {
    for (const [id, runtimeVersion, adapterId] of [
      ["oc1", "1.18.32", "opencode-v1"],
      ["oc2", "2.0.3", "opencode-v2"],
      ["undetected", null, null],
    ]) {
      assert.equal(observability.initObservability({
        aidevopsVersion: "3.37.7", runtimeVersion, adapterId,
      }), true);
      observability.handleEvent({ event: {
        type: "message.updated",
        properties: { info: {
          id, sessionID: `provenance-${id}`, role: "assistant",
          providerID: "openai", modelID: "gpt-5.6-luna", finish: "stop",
          time: { created: 1000, completed: 1100 },
          tokens: { input: 10, output: 5, total: 15 },
        } },
      } });
      await new Promise((resolve) => setTimeout(resolve, 100));
      const row = JSON.parse(sqlite.sqliteExecSync(`
        SELECT json_object('runtime', runtime_version, 'adapter', adapter_version)
        FROM llm_requests WHERE message_id = '${id}';
      `));
      assert.deepEqual(row, {
        runtime: runtimeVersion, adapter: adapterId ? `${adapterId}@3.37.7` : null,
      });
    }
  } finally {
    sqlite.shutdownSqlite();
    if (previousDb === undefined) delete process.env.AIDEVOPS_OBS_DB_OVERRIDE;
    else process.env.AIDEVOPS_OBS_DB_OVERRIDE = previousDb;
    if (previousVersion === undefined) delete process.env.OPENCODE_VERSION;
    else process.env.OPENCODE_VERSION = previousVersion;
    rmSync(root, { recursive: true, force: true });
  }
});
