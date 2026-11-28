// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { homedir } from "os";
import { join } from "path";
import { addApprovedCapabilityRules } from "./config-worker-permissions.mjs";
import { resolveReal } from "./permission-broker-read-only-root.mjs";

// These are runtime plumbing, not a grant to enumerate /dev or the home root.
// /proc remains gated: external_directory cannot express read-only proc access.
export function registerWorkerRuntimePermissions(config, env = process.env, home = homedir()) {
  if (!env.WORKER_WORKTREE_PATH || !env.WORKER_ISSUE_NUMBER) return 0;
  const tempRoot = join(home, ".aidevops", ".agent-workspace", "tmp");
  // external_directory grants cannot distinguish reads from writes. Everything
  // except the null sink is classified from the recorded operation by the broker.
  const patterns = ["/dev/null"];
  if (resolveReal(tempRoot) === join(resolveReal(home), ".aidevops", ".agent-workspace", "tmp")) {
    patterns.push(tempRoot, `${tempRoot}/**`);
  }
  let count = addApprovedCapabilityRules(config, [{ permission: "external_directory", patterns }]);
  for (const agent of Object.values(config.agent || {})) {
    count += addApprovedCapabilityRules(agent, [{ permission: "external_directory", patterns }]);
  }
  return count;
}
