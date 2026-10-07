// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "child_process";
import { existsSync } from "fs";

/**
 * Return a process start identity (`ps -o lstart=` in UTC/C locale), used with
 * the PID to distinguish process generations. Empty when unavailable, which
 * callers must treat as unproven.
 * @param {number} pid
 * @returns {string}
 */
export function processStartIdentity(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return "";
  const psBinary = existsSync("/bin/ps") ? "/bin/ps" : "ps";
  try {
    return execFileSync(
      psBinary,
      ["-p", String(pid), "-o", "lstart="],
      {
        encoding: "utf8",
        env: { ...process.env, LC_ALL: "C", TZ: "UTC" },
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 5000,
      },
    ).trim().replaceAll(/\s+/g, " ");
  } catch {
    return "";
  }
}

/**
 * Detect headless worker context from the plugin host environment.
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {boolean}
 */
export function isWorkerContext(env = process.env) {
  if (env.AIDEVOPS_WORKER_ID) return true;
  return [
    "FULL_LOOP_HEADLESS", "AIDEVOPS_HEADLESS", "OPENCODE_HEADLESS",
    "CLAUDE_HEADLESS", "Claude_HEADLESS", "HEADLESS", "GITHUB_ACTIONS",
  ]
    .some((key) => ["1", "true", "yes"].includes((env[key] || "").toLowerCase()));
}
