// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawn, spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

function boundedInteger(value, fallback, minimum, maximum) {
  value = Number(value);
  return Number.isFinite(value) ? Math.max(minimum, Math.min(maximum, Math.floor(value))) : fallback;
}

async function readPrivateConfig() {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > 70 * 1024) return null;
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return null;
  }
}

// Helpers such as timeout_sec move commands into their own process group
// (GNU timeout calls setpgid; the bash fallback uses `set -m`), outside the
// supervisor's group-wide signals (GH#33514). Track descendants by parent chain
// while they are attributable, keyed by PID plus start time so a reparented
// subtree stays owned and a reused PID is never signalled. Darwin `ps` reports
// no session IDs, so session membership cannot replace this attribution.
const TRACK_INTERVAL_MS = 250;

export function parseProcessSnapshot(text) {
  const entries = [];
  for (const line of String(text).split(/\r?\n/)) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\S.*)$/);
    if (!match) continue;
    entries.push({ pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]), started: match[4] });
  }
  return entries;
}

export function recordOwnedDescendants(snapshot, rootPid, owned, excludePid = 0) {
  const parents = new Set([rootPid]);
  for (const entry of snapshot) {
    if (owned.get(entry.pid)?.started === entry.started) parents.add(entry.pid);
  }
  let added = true;
  while (added) {
    added = false;
    for (const entry of snapshot) {
      if (entry.pid === rootPid || entry.pid === excludePid || parents.has(entry.pid)
        || !parents.has(entry.ppid)) continue;
      owned.set(entry.pid, { pgid: entry.pgid, started: entry.started });
      parents.add(entry.pid);
      added = true;
    }
  }
  return owned;
}

export function verifiedNestedTargets(snapshot, owned, ownGroup) {
  return snapshot
    .filter((entry) => entry.pgid !== ownGroup && owned.get(entry.pid)?.started === entry.started)
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

function signalEach(pids, signal) {
  for (const pid of pids) {
    try {
      process.kill(pid, signal);
    } catch {
      // Already exited between the snapshot and the signal.
    }
  }
}

function sendMessage(message) {
  if (typeof process.send !== "function") return Promise.resolve();
  return new Promise((resolve) => {
    try {
      process.send({ type: "aidevops.operation", ...message }, resolve);
    } catch {
      // The parent closes IPC during cancellation or an abnormal launcher exit.
      resolve();
    }
  });
}

function reportCommandStarted(operationID) {
  return sendMessage({
    event: "command_started",
    operationID: String(operationID || ""),
    runtime: `node ${process.version}`,
  });
}

export async function runSupervisor() {
  const config = await readPrivateConfig();
  const command = config?.command;
  if (!Array.isArray(command) || command.length === 0
    || command.some((part) => typeof part !== "string" || !part)) return 125;

  const budgetMs = boundedInteger(config.budgetMs, 15 * 60 * 1000, 10, 24 * 60 * 60 * 1000);
  const killGraceMs = boundedInteger(config.killGraceMs, 500, 10, 30 * 1000);
  let terminating = false;
  let childFinished = false;
  let childExit = 1;
  let commandStarted = Promise.resolve();
  const owned = new Map();
  const nestedGroups = new Set();
  let attributionComplete = true;

  // Returns the current snapshot after recording newly attributable descendants.
  const track = () => {
    const snapshot = processSnapshot();
    if (!snapshot) {
      attributionComplete = false;
      return null;
    }
    recordOwnedDescendants(snapshot.entries, process.pid, owned, snapshot.psPid);
    for (const entry of snapshot.entries) {
      if (entry.pgid !== process.pid && owned.get(entry.pid)?.started === entry.started) nestedGroups.add(entry.pgid);
    }
    return snapshot;
  };
  const nestedTargets = (snapshot) => (snapshot ? verifiedNestedTargets(snapshot.entries, owned, process.pid) : []);
  const reportContainment = () => sendMessage({
    event: "containment",
    operationID: String(config.operationID || ""),
    nestedProcessGroups: nestedGroups.size,
    attributionComplete,
  });

  const terminateOwnedGroup = () => {
    if (terminating) return;
    terminating = true;
    signalEach(nestedTargets(track()), "SIGTERM");
    try {
      process.kill(-process.pid, "SIGTERM");
    } catch {
      // The group may already contain only this supervisor.
    }
    setTimeout(() => {
      signalEach(nestedTargets(track()), "SIGKILL");
      reportContainment().finally(() => {
        try {
          process.kill(-process.pid, "SIGKILL");
        } catch {
          process.exit(1);
        }
      });
    }, killGraceMs).unref();
  };

  process.on("SIGTERM", terminateOwnedGroup);
  process.on("SIGINT", terminateOwnedGroup);
  process.on("message", (message) => {
    if (message?.action === "terminate") terminateOwnedGroup();
  });
  const budgetTimer = setTimeout(terminateOwnedGroup, budgetMs);

  const child = spawn(command[0], command.slice(1), {
    cwd: process.cwd(),
    env: { ...process.env, AIDEVOPS_OPERATION_ID: String(config.operationID || "") },
    stdio: ["ignore", "inherit", "inherit"],
  });

  const trackTimer = setInterval(track, TRACK_INTERVAL_MS);
  child.once("spawn", () => {
    commandStarted = reportCommandStarted(config.operationID);
    track();
  });
  child.once("error", () => {
    childFinished = true;
    childExit = 127;
  });
  child.once("exit", (code) => {
    childFinished = true;
    childExit = Number.isInteger(code) ? code : 1;
  });

  return new Promise((resolve) => {
    let draining = false;
    const drainTimer = setInterval(() => {
      if (!childFinished || draining) return;
      const snapshot = track();
      if (!snapshot) return;
      const members = snapshot.entries.filter((entry) => entry.pgid === process.pid).length;
      if (members !== 1) return;
      const nested = nestedTargets(snapshot);
      // Nested-group descendants keep inherited stdio open, so the operation is
      // not drained while they live. The budget still bounds them; once
      // termination has begun, escalate instead of waiting for the grace timer.
      if (nested.length > 0) {
        if (terminating) signalEach(nested, "SIGKILL");
        return;
      }
      draining = true;
      clearInterval(drainTimer);
      clearInterval(trackTimer);
      clearTimeout(budgetTimer);
      Promise.all([commandStarted, reportContainment()]).finally(() => resolve(childExit));
    }, 25);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(await runSupervisor());
}
