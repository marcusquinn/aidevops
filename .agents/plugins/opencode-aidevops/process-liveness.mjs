// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Per-process start tokens let recovery markers tell a live owner from a
// recycled PID. Linux reads /proc; macOS has no /proc and uses `ps -o lstart=`.

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

function procStartToken(pid) {
  try {
    // Field 22 follows the command in parentheses; splitting the prefix is unsafe.
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const fields = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
    return /^\d+$/.test(fields[19] || "") ? fields[19] : null;
  } catch {
    return null;
  }
}

function psStartToken(pid) {
  const result = spawnSync("ps", ["-o", "lstart=", "-p", String(pid)], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
    timeout: 2000,
  });
  const token = result.status === 0 ? result.stdout.trim().replace(/\s+/g, " ") : "";
  return token ? `ps:${token}` : null;
}

export function processStartToken(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return null;
  return procStartToken(pid) || psStartToken(pid);
}

// True only when the recorded owner PID is still the same running process.
export function isOwnerProcessLive(ownerPid, ownerStart) {
  if (typeof ownerStart !== "string" || !ownerStart) return false;
  return processStartToken(ownerPid) === ownerStart;
}
