// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { classifyLines, buildToast } from "../greeting.mjs";

test("gh prerequisite warnings become OpenCode warning toasts", () => {
  const buckets = classifyLines([
    "aidevops v3.15.32 running in OpenCode v1.14.48",
    "[WARN] GitHub CLI prerequisite: GitHub CLI (gh) detected version 2.45.0 is too old; gh api --paginate --slurp requires gh >= 2.51.0. On Ubuntu/Debian, avoid apt-pinned Ubuntu universe gh packages such as 2.45.0; install or upgrade from the official GitHub CLI package repository, then rerun aidevops status.",
  ].join("\n"));

  const toast = buildToast(buckets);
  assert.equal(toast.variant, "warning");
  assert.match(toast.message, /GitHub CLI prerequisite/);
  assert.match(toast.message, /requires gh >= 2\.51\.0/);
});
