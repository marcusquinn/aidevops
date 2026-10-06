// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";

export function parseProcessSnapshot(text) {
  const entries = [];
  for (const line of String(text).split(/\r?\n/)) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\S.*)$/);
    if (match) entries.push({ pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]), started: match[4] });
  }
  return entries;
}

function linuxFields(pid) {
  const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
  return stat.slice(stat.lastIndexOf(")") + 2).split(/\s+/);
}

export function linuxStartIdentity(pid) {
  try { return linuxFields(pid)[19]; } catch { return null; }
}

function linuxSnapshot() {
  const entries = [];
  for (const name of readdirSync("/proc")) {
    if (!/^\d+$/.test(name)) continue;
    try {
      const fields = linuxFields(name);
      // Zombies cannot consume resources and may persist under a subreaper.
      if (fields[0] !== "Z") entries.push({ pid: Number(name), ppid: Number(fields[1]), pgid: Number(fields[2]), started: fields[19] });
    } catch { /* process exited or is inaccessible */ }
  }
  return { entries, psPid: 0 };
}

export function processSnapshot() {
  try {
    if (process.platform === "linux") return linuxSnapshot();
    const result = spawnSync("ps", ["-ax", "-o", "pid=,ppid=,pgid=,lstart="], {
      detached: true, encoding: "utf8", env: { ...process.env, LC_ALL: "C" }, timeout: 1000,
    });
    return result.status === 0 ? { entries: parseProcessSnapshot(result.stdout), psPid: result.pid } : null;
  } catch { return null; }
}

function hasLinuxMarker(pid, operationID) {
  try {
    if (statSync(`/proc/${pid}`).uid !== process.getuid()) return false;
    return readFileSync(`/proc/${pid}/environ`, "utf8").split("\0").includes(`AIDEVOPS_OPERATION_ID=${operationID}`);
  } catch { return false; }
}

function darwinOperationPids(operationID) {
  const pids = new Set();
  const result = spawnSync("ps", ["axeww", "-o", "uid=,pid=,command="], {
    encoding: "utf8", timeout: 1000, maxBuffer: 8 * 1024 * 1024,
  });
  if (result.status !== 0) return pids;
  for (const line of result.stdout.split("\n")) {
    const [uid, pid, ...tokens] = line.trim().split(/\s+/);
    if (Number(uid) === process.getuid() && tokens.includes(`AIDEVOPS_OPERATION_ID=${operationID}`)) pids.add(Number(pid));
  }
  return pids;
}

export function markedProcesses(entries, operationID) {
  if (!operationID) return [];
  if (process.platform === "darwin") {
    const pids = darwinOperationPids(operationID);
    return entries.filter((entry) => pids.has(entry.pid));
  }
  return process.platform === "linux" ? entries.filter((entry) => hasLinuxMarker(entry.pid, operationID)) : [];
}
