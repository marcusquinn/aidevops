// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { join } from "path";

function isTrustedFullLoopCommitAndPr(command, scriptsDir, cwd) {
  const wrapperMatch = command.match(
    /(?:^|[($;|&\s])(?<wrapper>full-loop-helper\.sh|\.\/\.agents\/scripts\/full-loop-helper\.sh|\$PWD\/\.agents\/scripts\/full-loop-helper\.sh)\s+commit-and-pr(?:\s|$)/,
  );
  if (!wrapperMatch) return false;

  const wrapper = wrapperMatch.groups.wrapper;
  const expectedPath = wrapper === "full-loop-helper.sh"
    ? join(scriptsDir, wrapper)
    : join(cwd, ".agents", "scripts", "full-loop-helper.sh");
  return existsSync(expectedPath);
}

function isWorkerContext(env = process.env) {
  if (env.AIDEVOPS_WORKER_ID) return true;
  return [
    "FULL_LOOP_HEADLESS", "AIDEVOPS_HEADLESS", "OPENCODE_HEADLESS",
    "CLAUDE_HEADLESS", "Claude_HEADLESS", "HEADLESS", "GITHUB_ACTIONS",
  ]
    .some((key) => ["1", "true", "yes"].includes((env[key] || "").toLowerCase()));
}

export function checkCommandSafetyGate(command, scriptsDir, cwd = process.cwd(), options = {}) {
  if (typeof command !== "string" || !command) return;
  const helper = join(scriptsDir, "command-policy-helper.py");
  if (!existsSync(helper)) {
    throw new Error("BLOCKED: required command policy helper is missing");
  }
  // #aidevops:trust-boundary — only the repository-owned full-loop wrapper
  // receives nested Git authority, and only from a verified linked worktree.
  const guardedCommand = isTrustedFullLoopCommitAndPr(command, scriptsDir, cwd)
    ? "git commit --dry-run"
    : command;
  const helperArgs = [helper, "check-command", "--cwd", cwd, "--command", guardedCommand];
  const worker = options.worker ?? isWorkerContext();
  if (worker) {
    helperArgs.push(
      "--worker",
      "--worker-id",
      options.workerId || process.env.AIDEVOPS_WORKER_ID || "opencode-worker",
    );
  }
  let raw = "";
  try {
    raw = execFileSync(
      "python3",
      helperArgs,
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 10000,
      },
    );
  } catch (error) {
    raw = error?.stdout?.toString() || "";
    let result;
    try {
      result = JSON.parse(raw);
    } catch {
      const detail = error?.stderr?.toString().trim() || error?.message || "policy check failed";
      throw new Error(`BLOCKED: command policy failed closed: ${detail}`);
    }
    throw new Error(
      `BLOCKED by shared command policy (${result.decision || "forbid"}, ${result.rule_id || "policy.invalid-response"}): ${result.reason || "invalid policy response"}`,
    );
  }
  let result;
  try {
    result = JSON.parse(raw);
  } catch {
    throw new Error("BLOCKED: command policy returned malformed output");
  }
  if (result.decision !== "allow") {
    throw new Error(
      `BLOCKED by shared command policy (${result.decision || "forbid"}, ${result.rule_id || "policy.invalid-response"}): ${result.reason || "invalid policy response"}`,
    );
  }
}

export const checkCanonicalGitSafetyGate = checkCommandSafetyGate;
