// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawn } from "node:child_process";

import { isDirectEntrypoint } from "../../scripts/entrypoint-guard.mjs";
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
// separately (GH#33514); see bounded-operation-process-tree.mjs. Periodic
// ticks scan escaped-process markers only every MARKER_SCAN_INTERVAL_MS;
// exit, termination and drain decisions force that scan (GH#34324).
const TRACK_INTERVAL_MS = 250;
const MARKER_SCAN = Object.freeze({ markers: true });

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
function createTerminator(tracker, killGraceMs, reportContainment, reportTermination) {
  const state = { terminating: false };
  const signalNested = (signal) => {
    const snapshot = tracker.track(MARKER_SCAN);
    signalEach(tracker.nestedTargets(snapshot), signal, snapshot?.entries);
  };
  state.terminate = (cause) => {
    if (state.terminating) return;
    state.terminating = true;
    reportTermination(cause);
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

// A process inventory can still contain the command whose exit was observed.
// Attribute descendants first, then exclude only that completed start identity
// from drain decisions. A reused PID or any real descendant remains a survivor.
function survivorSnapshot(snapshot, exitedCommand) {
  if (!snapshot || !exitedCommand) return snapshot;
  return {
    ...snapshot,
    entries: snapshot.entries.filter((entry) => entry.pid !== exitedCommand.pid || entry.started !== exitedCommand.started),
  };
}

// True once only the supervisor remains in its group and no owned nested-group
// descendant is alive. Nested descendants keep inherited stdio open, so the
// operation is not drained while they live; the budget still bounds them, and
// once the main command has exited, survivors can be escalated without cutting
// short its TERM handler. Drain checks must never run while that command lives.
// A tree that looks drained is confirmed with a marker scan, so an escaped
// marked descendant is never missed between periodic scans (GH#34324).
function ownedTreeDrained(tracker, terminator, terminateSurvivors, exitedCommand) {
  let snapshot = survivorSnapshot(tracker.track(), exitedCommand);
  if (!snapshot) return false;
  if (tracker.ownGroupMembers(snapshot) === 1 && tracker.nestedTargets(snapshot).length === 0) {
    snapshot = survivorSnapshot(tracker.track(MARKER_SCAN), exitedCommand);
    if (!snapshot) return false;
  }
  const nested = tracker.nestedTargets(snapshot);
  if (nested.length || tracker.ownGroupMembers(snapshot) > 1) terminateSurvivors();
  // The main command is already gone: do not spend its TERM grace waiting on
  // same-group children. Signal individual snapshot identities, not our group,
  // so the supervisor stays alive to drain and report the original command exit.
  const sameGroup = tracker.ownGroupTargets(snapshot)
    .filter((pid) => pid !== process.pid && pid !== snapshot.psPid);
  if (terminator.terminating) signalEach(sameGroup, "SIGKILL", snapshot.entries);
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
  const killGraceMs = boundedInteger(config.killGraceMs, 500, 10, 300 * 1000);
  const result = { finished: false, exit: 1, started: Promise.resolve(), commandIdentity: null };
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
  let terminationReport = Promise.resolve();
  const reportTermination = (cause) => {
    terminationReport = sendMessage({ event: "termination", operationID, cause });
  };
  const terminator = createTerminator(tracker, killGraceMs, reportContainment, reportTermination);
  // Only cleanup started by command exit counts; budget and cancellation
  // terminations are already reported through the operation state.
  const terminateSurvivors = () => {
    if (!terminator.terminating) exitState.postExitDescendantsTerminated = true;
    terminator.terminate("post_exit_cleanup");
  };

  process.on("SIGTERM", () => terminator.terminate("signal_sigterm"));
  process.on("SIGINT", () => terminator.terminate("signal_sigint"));
  process.on("disconnect", () => terminator.terminate("parent_disconnect"));
  process.on("message", (message) => {
    if (message?.action !== "terminate") return;
    const cause = ["budget", "cancel", "dispose", "session_deleted"].includes(message.cause)
      ? message.cause : "cancel";
    terminator.terminate(cause);
  });
  const budgetTimer = setTimeout(() => terminator.terminate("budget"), budgetMs);

  const child = spawn(command[0], command.slice(1), {
    cwd: process.cwd(),
    env: { ...process.env, AIDEVOPS_OPERATION_ID: operationID, AIDEVOPS_OPERATION_OWNER_PID: String(process.pid) },
    stdio: ["ignore", "inherit", "inherit"],
  });

  const trackTimer = setInterval(tracker.track, TRACK_INTERVAL_MS);
  child.once("spawn", () => {
    result.started = reportCommandStarted(operationID);
    const snapshot = tracker.track();
    const entry = snapshot?.entries.find((entry) => entry.pid === child.pid);
    if (entry) result.commandIdentity = { pid: entry.pid, started: entry.started };
  });
  child.once("error", () => {
    result.finished = true;
    result.exit = 127;
    if (!terminator.terminating) reportTermination("spawn_error");
  });
  child.once("exit", (code) => {
    result.finished = true;
    result.exit = Number.isInteger(code) ? code : 1;
    // Command completion also owns cleanup of servers with detached stdio.
    // Preserve its exit status while draining any surviving owned descendants.
    const snapshot = survivorSnapshot(tracker.track(MARKER_SCAN), result.commandIdentity);
    if (snapshot && (tracker.nestedTargets(snapshot).length || tracker.ownGroupMembers(snapshot) > 1)) {
      terminateSurvivors();
    }
  });

  return new Promise((resolve) => {
    const drainTimer = setInterval(() => {
      if (!result.finished || !ownedTreeDrained(tracker, terminator, terminateSurvivors, result.commandIdentity)) return;
      clearInterval(drainTimer);
      clearInterval(trackTimer);
      clearTimeout(budgetTimer);
      Promise.all([result.started, terminationReport, reportContainment()]).finally(() => resolve(result.exit));
    }, 25);
  });
}

if (isDirectEntrypoint(import.meta.url)) {
  process.exit(await runSupervisor());
}
