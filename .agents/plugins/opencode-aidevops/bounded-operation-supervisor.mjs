// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

import { createProcessTreeTracker, signalEach } from "./bounded-operation-process-tree.mjs";

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

// Nested process groups created by helpers such as timeout_sec are tracked
// separately (GH#33514); see bounded-operation-process-tree.mjs.
const TRACK_INTERVAL_MS = 250;

function signalOwnGroup(signal) {
  try {
    process.kill(-process.pid, signal);
    return true;
  } catch {
    // The group may already contain only this supervisor.
    return false;
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

function validCommand(command) {
  return Array.isArray(command) && command.length > 0
    && command.every((part) => typeof part === "string" && part);
}

// Signals nested helper groups before and after the grace period, then the
// supervisor's own group. Containment is reported before the final SIGKILL.
function createTerminator(tracker, killGraceMs, reportContainment) {
  const state = { terminating: false };
  const signalNested = (signal) => {
    const snapshot = tracker.track();
    signalEach(tracker.nestedTargets(snapshot), signal, snapshot?.entries);
  };
  state.terminate = () => {
    if (state.terminating) return;
    state.terminating = true;
    signalNested("SIGTERM");
    signalOwnGroup("SIGTERM");
    setTimeout(() => {
      signalNested("SIGKILL");
      reportContainment().finally(() => {
        if (!signalOwnGroup("SIGKILL")) process.exit(1);
      });
    }, killGraceMs).unref();
  };
  return state;
}

// True once only the supervisor remains in its group and no owned nested-group
// descendant is alive. Nested descendants keep inherited stdio open, so the
// operation is not drained while they live; the budget still bounds them, and
// once termination has begun they are escalated instead of awaiting the grace.
function ownedTreeDrained(tracker, terminator, terminateSurvivors) {
  const snapshot = tracker.track();
  if (!snapshot) return false;
  const nested = tracker.nestedTargets(snapshot);
  if (nested.length || tracker.ownGroupMembers(snapshot) > 1) terminateSurvivors();
  if (tracker.ownGroupMembers(snapshot) !== 1) return false;
  if (nested.length === 0) return true;
  if (terminator.terminating) signalEach(nested, "SIGKILL", snapshot.entries);
  return false;
}

export async function runSupervisor() {
  const config = await readPrivateConfig();
  if (!validCommand(config?.command)) return 125;
  const { command } = config;
  const operationID = String(config.operationID || "");

  const budgetMs = boundedInteger(config.budgetMs, 15 * 60 * 1000, 10, 24 * 60 * 60 * 1000);
  const killGraceMs = boundedInteger(config.killGraceMs, 500, 10, 30 * 1000);
  const result = { finished: false, exit: 1, started: Promise.resolve() };
  const tracker = createProcessTreeTracker(process.pid, undefined, operationID);
  // GH#34047: distinguish "exited 0 with nothing left" from "exited 0, then
  // cleanup terminated surviving descendants" (for example a detached worker).
  const exitState = { postExitDescendantsTerminated: false };
  const reportContainment = () => sendMessage({
    event: "containment",
    operationID,
    ...tracker.containment(),
    postExitDescendantsTerminated: exitState.postExitDescendantsTerminated,
  });
  const terminator = createTerminator(tracker, killGraceMs, reportContainment);
  // Only cleanup started by command exit counts; budget and cancellation
  // terminations are already reported through the operation state.
  const terminateSurvivors = () => {
    if (!terminator.terminating) exitState.postExitDescendantsTerminated = true;
    terminator.terminate();
  };

  process.on("SIGTERM", terminator.terminate);
  process.on("SIGINT", terminator.terminate);
  process.on("message", (message) => {
    if (message?.action === "terminate") terminator.terminate();
  });
  const budgetTimer = setTimeout(terminator.terminate, budgetMs);

  const child = spawn(command[0], command.slice(1), {
    cwd: process.cwd(),
    env: { ...process.env, AIDEVOPS_OPERATION_ID: operationID, AIDEVOPS_OPERATION_OWNER_PID: String(process.pid) },
    stdio: ["ignore", "inherit", "inherit"],
  });

  const trackTimer = setInterval(tracker.track, TRACK_INTERVAL_MS);
  child.once("spawn", () => {
    result.started = reportCommandStarted(operationID);
    tracker.track();
  });
  child.once("error", () => {
    result.finished = true;
    result.exit = 127;
  });
  child.once("exit", (code) => {
    result.finished = true;
    result.exit = Number.isInteger(code) ? code : 1;
    // Command completion also owns cleanup of servers with detached stdio.
    // Preserve its exit status while draining any surviving owned descendants.
    const snapshot = tracker.track();
    if (snapshot && (tracker.nestedTargets(snapshot).length || tracker.ownGroupMembers(snapshot) > 1)) {
      terminateSurvivors();
    }
  });

  return new Promise((resolve) => {
    const drainTimer = setInterval(() => {
      if (!result.finished || !ownedTreeDrained(tracker, terminator, terminateSurvivors)) return;
      clearInterval(drainTimer);
      clearInterval(trackTimer);
      clearTimeout(budgetTimer);
      Promise.all([result.started, reportContainment()]).finally(() => resolve(result.exit));
    }, 25);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(await runSupervisor());
}
