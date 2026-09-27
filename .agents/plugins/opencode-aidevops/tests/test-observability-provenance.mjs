// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { requestProvenance } from "../observability-provenance.mjs";

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
