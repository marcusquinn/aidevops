// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawnSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";

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
  const result = spawnSync("ps", ["-ax", "-o", "pid=,ppid=,pgid=,lstart="], {
    detached: true,
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
    timeout: 1000,
  });
  if (result.status !== 0) return null;
  return { entries: parseProcessSnapshot(result.stdout), psPid: result.pid };
}

export function signalEach(pids, signal) {
  for (const pid of pids) {
    try {
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
    // Recover children which double-forked/setsid before the first parent-chain
    // snapshot. Never retain or log unrelated environment values (GH#33747).
    if (operationID) {
      for (const entry of snapshot.entries) {
        if (entry.pid === rootPid || entry.pid === snapshot.psPid) continue;
        if (hasOperationMarker(entry.pid, operationID)) {
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
    if (process.platform === "darwin") {
      const result = spawnSync("ps", ["eww", "-p", String(pid), "-o", "command="], {
        encoding: "utf8", timeout: 1000,
      });
      return result.status === 0 && result.stdout.split(/\s+/).includes(marker);
    }
  } catch {
    // Exited or inaccessible: parent-chain attribution remains available.
  }
  return false;
}
