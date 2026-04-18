// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Test suite for otel-enrichment.mjs (t2181 regression guard)
// ---------------------------------------------------------------------------
// Runs under the built-in `node:test` runner. No external deps.
//
//   node --test .agents/plugins/opencode-aidevops/tests/
//
// or to run just this file:
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-otel-enrichment.mjs
//
// Scope: pure-function coverage of detectTaskId and detectSessionOrigin.
// `enrichActiveSpan` / `otelEnabled` depend on a live @opentelemetry/api
// context manager and are smoke-tested via manual end-to-end runs against
// Jaeger (see reference/observability.md).
// ---------------------------------------------------------------------------

import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";

import {
  detectTaskId,
  detectSessionOrigin,
  otelEnabled,
} from "../otel-enrichment.mjs";

// ---------------------------------------------------------------------------
// detectTaskId — path shapes
// ---------------------------------------------------------------------------

describe("detectTaskId — worktree path shapes", () => {
  const originalTaskIdEnv = process.env.AIDEVOPS_TASK_ID;

  before(() => {
    delete process.env.AIDEVOPS_TASK_ID;
  });

  after(() => {
    if (originalTaskIdEnv !== undefined) {
      process.env.AIDEVOPS_TASK_ID = originalTaskIdEnv;
    } else {
      delete process.env.AIDEVOPS_TASK_ID;
    }
  });

  test("wt default: ~/Git/<repo>.feature-tNNNN-name (dot separator)", () => {
    assert.equal(
      detectTaskId("/Users/x/Git/aidevops.feature-t2177-otel-introspect"),
      "t2177",
    );
  });

  test("wt legacy: ~/Git/<repo>-feature-tNNNN-name (dash separator)", () => {
    assert.equal(
      detectTaskId("/home/user/Git/myrepo-bugfix-t42-quickfix"),
      "t42",
    );
  });

  test("git worktree default: <path>/feature/tNNNN-name (slash separator)", () => {
    assert.equal(
      detectTaskId("/home/ci/project/worktrees/feature/t100-desc"),
      "t100",
    );
  });

  test("GH# form with dot separator: <repo>.bugfix-gh-NNNNN-name", () => {
    assert.equal(
      detectTaskId("/Users/x/Git/aidevops.bugfix-gh-19634-zombie"),
      "GH#19634",
    );
  });

  test("GH# form with slash separator: feature/gh-NNNNN-name", () => {
    assert.equal(
      detectTaskId("/home/ci/project/feature/gh-10521-thing"),
      "GH#10521",
    );
  });

  test("terminal task ID: path ends with tNNNN (no trailing separator)", () => {
    assert.equal(
      detectTaskId("/Users/x/Git/aidevops.feature-t2181"),
      "t2181",
    );
  });

  test("terminal GH# ID: path ends with gh-NNN", () => {
    assert.equal(
      detectTaskId("/home/user/Git/myrepo-hotfix-gh-42"),
      "GH#42",
    );
  });

  test("start-of-string: bare 'tNNNN-name' works when passed directly", () => {
    assert.equal(detectTaskId("t2177-standalone"), "t2177");
  });

  test("false-positive guard: 'patient123' does not match t123", () => {
    // 'patient' has 't' preceded by 'a' (alphanum) — no match.
    assert.equal(detectTaskId("/home/user/patient123/stuff"), "");
  });

  test("false-positive guard: 'testing' does not match", () => {
    // 'testing' has 't' preceded by '/' but followed by 'e', not digits.
    assert.equal(detectTaskId("/home/user/testing/notatask"), "");
  });

  test("false-positive guard: 'ghastly' does not match gh-form", () => {
    // 'ghastly' has 'gh' but not followed by '-<digits>'.
    assert.equal(detectTaskId("/path/with/ghastly/dir"), "");
  });

  test("returns '' when cwd contains no task-id-like token", () => {
    assert.equal(detectTaskId("/Users/x/Git/aidevops"), "");
  });
});

// ---------------------------------------------------------------------------
// detectTaskId — env var precedence
// ---------------------------------------------------------------------------

describe("detectTaskId — AIDEVOPS_TASK_ID env var", () => {
  test("env var overrides cwd parsing when valid", () => {
    const original = process.env.AIDEVOPS_TASK_ID;
    try {
      process.env.AIDEVOPS_TASK_ID = "t9999";
      assert.equal(
        detectTaskId("/Users/x/Git/aidevops.feature-t2177-other"),
        "t9999",
      );
    } finally {
      if (original !== undefined) process.env.AIDEVOPS_TASK_ID = original;
      else delete process.env.AIDEVOPS_TASK_ID;
    }
  });

  test("env var accepts GH# form", () => {
    const original = process.env.AIDEVOPS_TASK_ID;
    try {
      process.env.AIDEVOPS_TASK_ID = "GH#12345";
      assert.equal(detectTaskId("/some/unrelated/path"), "GH#12345");
    } finally {
      if (original !== undefined) process.env.AIDEVOPS_TASK_ID = original;
      else delete process.env.AIDEVOPS_TASK_ID;
    }
  });

  test("malformed env var falls back to cwd parsing", () => {
    const original = process.env.AIDEVOPS_TASK_ID;
    try {
      process.env.AIDEVOPS_TASK_ID = "garbage";
      assert.equal(
        detectTaskId("/Users/x/Git/aidevops.feature-t2177-other"),
        "t2177",
      );
    } finally {
      if (original !== undefined) process.env.AIDEVOPS_TASK_ID = original;
      else delete process.env.AIDEVOPS_TASK_ID;
    }
  });
});

// ---------------------------------------------------------------------------
// detectSessionOrigin
// ---------------------------------------------------------------------------

describe("detectSessionOrigin", () => {
  const envKeys = [
    "FULL_LOOP_HEADLESS",
    "AIDEVOPS_HEADLESS",
    "OPENCODE_HEADLESS",
    "CLAUDE_HEADLESS",
    "GITHUB_ACTIONS",
  ];
  const saved = {};

  before(() => {
    for (const k of envKeys) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });

  after(() => {
    for (const k of envKeys) {
      if (saved[k] !== undefined) process.env[k] = saved[k];
      else delete process.env[k];
    }
  });

  test("returns 'interactive' when no headless env is set", () => {
    assert.equal(detectSessionOrigin(), "interactive");
  });

  test("returns 'worker' when FULL_LOOP_HEADLESS=1", () => {
    process.env.FULL_LOOP_HEADLESS = "1";
    try {
      assert.equal(detectSessionOrigin(), "worker");
    } finally {
      delete process.env.FULL_LOOP_HEADLESS;
    }
  });

  test("returns 'worker' when GITHUB_ACTIONS=true", () => {
    process.env.GITHUB_ACTIONS = "true";
    try {
      assert.equal(detectSessionOrigin(), "worker");
    } finally {
      delete process.env.GITHUB_ACTIONS;
    }
  });

  test("returns 'worker' when AIDEVOPS_HEADLESS is any non-empty value", () => {
    process.env.AIDEVOPS_HEADLESS = "yes";
    try {
      assert.equal(detectSessionOrigin(), "worker");
    } finally {
      delete process.env.AIDEVOPS_HEADLESS;
    }
  });
});

// ---------------------------------------------------------------------------
// otelEnabled — cold-start state
// ---------------------------------------------------------------------------

describe("otelEnabled", () => {
  test("returns false before any enrichActiveSpan() call has loaded the api", () => {
    // The module's internal _traceApi is lazily populated on first
    // enrichActiveSpan() invocation. Before that, otelEnabled() is a cheap
    // "definitely not ready" signal. Callers use it to skip attribute
    // building when OTEL is disabled, so `false` here is the contract.
    assert.equal(otelEnabled(), false);
  });
});
