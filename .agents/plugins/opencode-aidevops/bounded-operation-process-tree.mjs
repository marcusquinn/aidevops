// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { linuxStartIdentity, markedProcesses, processSnapshot } from "./bounded-operation-process-snapshot.mjs";
export { parseProcessSnapshot } from "./bounded-operation-process-snapshot.mjs";

// Track parent-chain descendants before reparenting (GH#33514); recover escaped
// children using exact same-user operation markers (GH#33747). Retain PID/start
// identity so a reparented subtree remains owned without adopting reused PIDs.
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
  return snapshot.filter((entry) => entry.pgid !== ownGroup && isOwned(owned, entry)).map((entry) => entry.pid);
}

export function signalEach(pids, signal, entries = []) {
  for (const pid of pids) {
    try {
      const expected = entries.find((entry) => entry.pid === pid);
      if (!expected) continue;
      if (process.platform === "linux" && linuxStartIdentity(pid) !== expected.started) continue;
      process.kill(pid, signal);
    } catch { /* exited between the snapshot and signal */ }
  }
}

function recoverMarked(snapshot, rootPid, owned, operationID) {
  const candidates = snapshot.entries.filter((entry) => entry.pid !== rootPid && entry.pid !== snapshot.psPid && !isOwned(owned, entry));
  for (const entry of markedProcesses(candidates, operationID)) {
    owned.set(entry.pid, { pgid: entry.pgid, started: entry.started });
  }
}

function recordSnapshot(snapshot, rootPid, owned, operationID, nestedGroups) {
  recordOwnedDescendants(snapshot.entries, rootPid, owned, snapshot.psPid);
  recoverMarked(snapshot, rootPid, owned, operationID);
  recordOwnedDescendants(snapshot.entries, rootPid, owned, snapshot.psPid);
  for (const entry of snapshot.entries) {
    if (entry.pgid !== rootPid && isOwned(owned, entry)) nestedGroups.add(entry.pgid);
  }
}

export function createProcessTreeTracker(rootPid, snapshotProcesses = processSnapshot, operationID = "") {
  const owned = new Map();
  const nestedGroups = new Set();
  let attributionComplete = true;
  const track = () => {
    const snapshot = snapshotProcesses();
    if (!snapshot) {
      attributionComplete = false;
      return null;
    }
    recordSnapshot(snapshot, rootPid, owned, operationID, nestedGroups);
    return snapshot;
  };
  return {
    track,
    nestedTargets: (snapshot) => (snapshot ? verifiedNestedTargets(snapshot.entries, owned, rootPid) : []),
    ownGroupMembers: (snapshot) => snapshot.entries.filter((entry) => entry.pgid === rootPid).length,
    containment: () => ({ nestedProcessGroups: nestedGroups.size, attributionComplete }),
  };
}
