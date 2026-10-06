// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";

// Helpers such as timeout_sec move commands into their own process group
// (GNU timeout calls setpgid; the bash fallback uses `set -m`), outside the
// supervisor's group-wide signals (GH#33514). Track descendants by parent chain
// while they are attributable, keyed by PID plus start time so a reparented
// subtree stays owned and a reused PID is never signalled. Darwin `ps` reports
// no session IDs, so session membership cannot replace this attribution.

export function parseProcessSnapshot(text) {
  const entries = [];
  for (const line of String(text).split(/\r?\n/)) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\S.*)$/);
    if (!match) continue;
    entries.push({ pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]), started: match[4] });
  }
  return entries;
}

function isOwned(owned, entry) {
  return owned.get(entry.pid)?.started === entry.started;
}

export function recordOwnedDescendants(snapshot, rootPid, owned, excludePid = 0) {
  const parents = new Set([rootPid]);
  for (const entry of snapshot) {
    if (isOwned(owned, entry)) parents.add(entry.pid);
  }
  const candidates = snapshot.filter((entry) => entry.pid !== rootPid && entry.pid !== excludePid);
  let added = true;
  while (added) {
    added = false;
    for (const entry of candidates) {
      if (parents.has(entry.pid) || !parents.has(entry.ppid)) continue;
      owned.set(entry.pid, { pgid: entry.pgid, started: entry.started });
      parents.add(entry.pid);
      added = true;
    }
  }
  return owned;
}

export function verifiedNestedTargets(snapshot, owned, ownGroup) {
  return snapshot
    .filter((entry) => entry.pgid !== ownGroup && isOwned(owned, entry))
    .map((entry) => entry.pid);
}

function processSnapshot() {
  if (process.platform === "linux") {
    try {
      const entries = [];
      for (const name of readdirSync("/proc")) {
        if (!/^\d+$/.test(name)) continue;
        try {
          const stat = readFileSync(`/proc/${name}/stat`, "utf8");
          const fields = stat.slice(stat.lastIndexOf(")") + 2).split(/\s+/);
          // Zombies cannot consume resources and may persist under a subreaper.
          if (fields[0] === "Z") continue;
          entries.push({ pid: Number(name), ppid: Number(fields[1]), pgid: Number(fields[2]), started: fields[19] });
        } catch { /* process exited or is inaccessible */ }
      }
      return { entries, psPid: 0 };
    } catch {
      return null;
    }
  }
  const result = spawnSync("ps", ["-ax", "-o", "pid=,ppid=,pgid=,lstart="], {
    detached: true,
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
    timeout: 1000,
  });
  if (result.status !== 0) return null;
  return { entries: parseProcessSnapshot(result.stdout), psPid: result.pid };
}

function linuxStartIdentity(pid) {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    return stat.slice(stat.lastIndexOf(")") + 2).split(/\s+/)[19];
  } catch {
    return null;
  }
}

export function signalEach(pids, signal, entries = []) {
  for (const pid of pids) {
    try {
      const expected = entries.find((entry) => entry.pid === pid);
      if (!expected) continue;
      if (process.platform === "linux" && linuxStartIdentity(pid) !== expected.started) continue;
      process.kill(pid, signal);
    } catch {
      // Already exited between the snapshot and the signal.
    }
  }
}

// Tracks descendants of rootPid (whose own process group is rootPid) and the
// nested process groups they moved into.
export function createProcessTreeTracker(rootPid, snapshotProcesses = processSnapshot, operationID = "") {
  const owned = new Map();
  const nestedGroups = new Set();
  let attributionComplete = true;

  // Returns the current snapshot after recording newly attributable descendants.
  const track = () => {
    const snapshot = snapshotProcesses();
    if (!snapshot) {
      attributionComplete = false;
      return null;
    }
    recordOwnedDescendants(snapshot.entries, rootPid, owned, snapshot.psPid);
    // Recover children which double-forked/setsid before the first parent-chain
    // snapshot. Never retain or log unrelated environment values (GH#33747).
    if (operationID) {
      const darwinPids = process.platform === "darwin" ? darwinOperationPids(operationID) : null;
      for (const entry of snapshot.entries) {
        if (entry.pid === rootPid || entry.pid === snapshot.psPid || isOwned(owned, entry)) continue;
        if (darwinPids ? darwinPids.has(entry.pid) : hasOperationMarker(entry.pid, operationID)) {
          owned.set(entry.pid, { pgid: entry.pgid, started: entry.started });
        }
      }
    }
    recordOwnedDescendants(snapshot.entries, rootPid, owned, snapshot.psPid);
    for (const entry of snapshot.entries) {
      if (entry.pgid !== rootPid && isOwned(owned, entry)) nestedGroups.add(entry.pgid);
    }
    return snapshot;
  };

  return {
    track,
    nestedTargets: (snapshot) => (snapshot ? verifiedNestedTargets(snapshot.entries, owned, rootPid) : []),
    ownGroupMembers: (snapshot) => snapshot.entries.filter((entry) => entry.pgid === rootPid).length,
    containment: () => ({ nestedProcessGroups: nestedGroups.size, attributionComplete }),
  };
}

function hasOperationMarker(pid, operationID) {
  try {
    const marker = `AIDEVOPS_OPERATION_ID=${operationID}`;
    if (process.platform === "linux") {
      if (statSync(`/proc/${pid}`).uid !== process.getuid()) return false;
      return readFileSync(`/proc/${pid}/environ`, "utf8").split("\0").includes(marker);
    }
  } catch {
    // Exited or inaccessible: parent-chain attribution remains available.
  }
  return false;
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
