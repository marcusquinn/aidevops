// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";

export function parseProcessSnapshot(text) {
  const entries = [];
  for (const line of String(text).split(/\r?\n/)) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S.*)$/);
    if (match && !match[4].startsWith("Z")) entries.push({ pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]), started: match[5] });
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

// TZ=UTC0 is a POSIX zone string: macOS libc otherwise reloads a zone file for
// every lstart row, so a ~1,000-process read took ~0.6 s wall (~1 s under load,
// at this 1 s timeout) instead of ~40 ms. Identities only compare within one
// tracker, so the zone only has to be consistent.
// GH#40309: a listing that overruns its bound on a loaded host is a delayed
// tick, not missing attribution (timer ticks carry no latency guarantee
// either). Retry a timed-out read once with a longer bound; only an inventory
// that stays unavailable marks containment incomplete.
const PS_SNAPSHOT_TIMEOUTS_MS = [1000, 5000];

function psSnapshot() {
  for (const timeout of PS_SNAPSHOT_TIMEOUTS_MS) {
    const result = spawnSync("ps", ["-ax", "-o", "pid=,ppid=,pgid=,stat=,lstart="], {
      detached: true, encoding: "utf8", env: { ...process.env, LC_ALL: "C", TZ: "UTC0" }, timeout,
    });
    if (result.status === 0) return { entries: parseProcessSnapshot(result.stdout), psPid: result.pid };
    if (result.error?.code !== "ETIMEDOUT") return null;
  }
  return null;
}

export function processSnapshot() {
  try {
    return process.platform === "linux" ? linuxSnapshot() : psSnapshot();
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
  let result;
  for (const timeout of PS_SNAPSHOT_TIMEOUTS_MS) {
    result = spawnSync("ps", ["axeww", "-o", "uid=,pid=,command="], {
      encoding: "utf8", timeout, maxBuffer: 8 * 1024 * 1024,
    });
    if (result.error?.code !== "ETIMEDOUT") break;
  }
  // Unavailable inventory is distinct from a successful scan with no matches.
  if (result.status !== 0) return null;
  for (const line of result.stdout.split("\n")) {
    const [uid, pid, ...tokens] = line.trim().split(/\s+/);
    if (Number(uid) === process.getuid() && tokens.includes(`AIDEVOPS_OPERATION_ID=${operationID}`)) pids.add(Number(pid));
  }
  return pids;
}

// Returns null when the marker inventory is unavailable (attribution unknown).
export function markedProcesses(entries, operationID) {
  if (!operationID) return [];
  if (process.platform === "darwin") {
    const pids = darwinOperationPids(operationID);
    if (!pids) return null;
    return entries.filter((entry) => pids.has(entry.pid));
  }
  return process.platform === "linux" ? entries.filter((entry) => hasLinuxMarker(entry.pid, operationID)) : [];
}
