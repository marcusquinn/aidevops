// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { spawn } from "child_process";

/**
 * Run loop-mode checks in their own process group so a timeout cannot leave a
 * helper running long enough to create a worktree after the tool has returned.
 * @param {string} script
 * @param {string[]} args
 * @param {string} cwd
 * @param {number} timeoutMs
 * @param {object} [context] - OpenCode tool context
 * @returns {Promise<{code: number|null, stdout: string, stderr: string, timedOut: boolean, error?: Error}>}
 */
export function runPreEditCheck(script, args, cwd, timeoutMs, context) {
  return new Promise((resolve) => {
    const sessionID = String(context?.sessionID || "");
    // The plugin may run in a transport process. Keep the runtime identity
    // delivered by OpenCode's environment when it belongs to this caller,
    // rather than replacing the same-session Bash owner's PID unconditionally.
    let ownerPID = String(process.pid);
    const inheritedPID = process.env.OPENCODE_PID || "";
    if (sessionID === process.env.OPENCODE_SESSION_ID && /^[1-9][0-9]*$/.test(inheritedPID)) {
      try {
        process.kill(Number(inheritedPID), 0);
        ownerPID = inheritedPID;
      } catch {
        // Missing or inaccessible liveness evidence is not an owner override.
      }
    }
    const sessionEnv = /^ses_[A-Za-z0-9_-]+$/.test(sessionID)
      ? {
          OPENCODE: "1",
          OPENCODE_PID: ownerPID,
          OPENCODE_SESSION_ID: sessionID,
          AIDEVOPS_OPENCODE_SESSION_ID: sessionID,
        }
      : {};
    const child = spawn("bash", [script, ...args], {
      cwd,
      detached: true,
      env: { ...process.env, ...sessionEnv },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let spawnError;

    child.stdout.setEncoding("utf-8");
    child.stderr.setEncoding("utf-8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => { spawnError = error; });

    const timer = setTimeout(() => {
      timedOut = true;
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    }, timeoutMs);

    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, timedOut, error: spawnError });
    });
  });
}
