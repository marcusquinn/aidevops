// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import { registerManagedDirectoryPermissions } from "../config-hook.mjs";

const managedRules = {
  "~/.aidevops": "allow",
  "~/.aidevops/**": "allow",
  "~/.config/aidevops": "allow",
  "~/.config/aidevops/**": "allow",
  "~/Git/_worktrees": "allow",
  "~/Git/_worktrees/**": "allow",
};

test("adds narrow managed-directory exceptions after a broad ask rule", () => {
  const config = {
    permission: {
      external_directory: {
        "*": "ask",
        "~/Documents/**": "deny",
      },
    },
  };

  assert.equal(registerManagedDirectoryPermissions(config), 6);
  assert.deepEqual(config.permission.external_directory, {
    "*": "ask",
    "~/Documents/**": "deny",
    ...managedRules,
  });
});

test("converts a top-level default without allowing unrelated directories", () => {
  const config = { permission: "ask" };

  assert.equal(registerManagedDirectoryPermissions(config), 6);
  assert.equal(config.permission["*"], "ask");
  assert.deepEqual(config.permission.external_directory, {
    "*": "ask",
    ...managedRules,
  });
});

test("leaves an existing global external-directory allow unchanged", () => {
  const config = { permission: { external_directory: "allow", read: "ask" } };

  assert.equal(registerManagedDirectoryPermissions(config), 0);
  assert.deepEqual(config.permission, { external_directory: "allow", read: "ask" });
});

test("is idempotent and keeps managed rules last", () => {
  const config = { permission: { external_directory: { "*": "ask" } } };

  assert.equal(registerManagedDirectoryPermissions(config), 6);
  assert.equal(registerManagedDirectoryPermissions(config), 0);
  assert.deepEqual(Object.keys(config.permission.external_directory).slice(-6), Object.keys(managedRules));
});

test("adds managed rules to per-agent permissions that override top-level defaults", () => {
  const config = {
    permission: { external_directory: { "*": "ask" } },
    agent: {
      "Build+": { permission: { external_directory: "ask", bash: "allow" } },
      review: { permission: { read: "allow" } },
    },
  };

  assert.equal(registerManagedDirectoryPermissions(config), 18);
  assert.deepEqual(config.agent["Build+"].permission.external_directory, {
    "*": "ask",
    ...managedRules,
  });
  assert.deepEqual(config.agent.review.permission.external_directory, managedRules);
});
