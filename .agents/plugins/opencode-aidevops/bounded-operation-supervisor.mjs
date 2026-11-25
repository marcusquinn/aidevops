// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

import { isDirectEntrypoint } from "../../scripts/entrypoint-guard.mjs";
import { createProcessTreeTracker, signalEach } from "./bounded-operation-process-tree.mjs";
import { admitWithContentionWait } from "./admission-wait.mjs";
import { admitToolOwner } from "./lifecycle-admission.mjs";

export { admitWithContentionWait, contentionWaitMs } from "./admission-wait.mjs";

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

// After the command has exited, the self-inclusive group SIGKILL waits this long
// for the drain to report its status. It only bounds survivors that outlive SIGKILL.
const EXITED_COMMAND_BACKSTOP_MS = 10_000;

// Signals nested helper groups before and after the grace period, then the
// supervisor's own group. Containment is reported before the final SIGKILL.
// GH#40309: on a loaded host a command can exit inside its grace while the
// drain's process scans are still running when the grace timer fires; killing
// the supervisor then turned a clean exit-0 timeout into an unknown exit.
function createTerminator(tracker, killGraceMs, reportContainment, reportTermination, commandExited) {
  const state = { terminating: false, postExit: false, drained: false };
  const timers = [];
  const later = (callback, milliseconds) => timers.push(setTimeout(callback, milliseconds).unref());
  // The drain has reported the command's status: no pending escalation may
  // signal the supervisor that is reporting it.
  state.settle = () => {
    state.drained = true;
    timers.forEach(clearTimeout);
  };
  const signalNested = (signal) => {
    const snapshot = tracker.track(MARKER_SCAN);
    signalEach(tracker.nestedTargets(snapshot), signal, snapshot?.entries);
  };
  const killGroup = () => signalOwnGroup("SIGKILL") || process.exit(1);
  // An exited command's status is already known: remove the survivors but
  // keep the supervisor to drain and report it, without discarding that
  // status; the group SIGKILL stays as the backstop for anything that outlives SIGKILL.
  const containOwnGroup = () => {
    if (!commandExited() || !tracker.killOwnGroupOthers()) return killGroup();
    later(killGroup, Math.max(killGraceMs, EXITED_COMMAND_BACKSTOP_MS));
  };
  const escalate = (postExit) => {
    signalNested("SIGKILL");
    // The command's exit was already observed: a post-exit drain never
    // signals our own group (GH#39251); takeover timers are non-postExit.
    // The drain can also settle while containment is being reported.
    reportContainment().finally(() => postExit || state.drained || containOwnGroup());
  };
  state.terminate = (cause) => {
    const postExit = cause === "post_exit_cleanup";
    // Post-exit cleanup is a drain: a budget, cancel or signal may take over.
    if (state.terminating && !(state.postExit && !postExit)) return;
    state.terminating = true;
    state.postExit = postExit;
    reportTermination(cause);
    signalNested("SIGTERM");
    if (!postExit) signalOwnGroup("SIGTERM");
    later(() => escalate(postExit), killGraceMs);
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
// GH#40309: the command's identity is read after each scan records it, so an
// inventory that missed the spawn (a loaded host) still excludes a stale
// listing of the exited command instead of counting it as a survivor.
function ownedTreeDrained(tracker, terminator, terminateSurvivors, commandPid) {
  let snapshot = survivorSnapshot(tracker.track(), tracker.identity(commandPid));
  if (snapshot && tracker.ownGroupMembers(snapshot) === 1 && tracker.nestedTargets(snapshot).length === 0) {
    snapshot = survivorSnapshot(tracker.track(MARKER_SCAN), tracker.identity(commandPid));
  }
  if (!snapshot) return false;
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

async function admitSupervisor(command, operationID) {
  // This existing supervisor owns the operation until its normal drain completes.
  // Register its native identity before spawning, independently of the UI owner.
  const supervised = process.connected === true;
  // Admission can wait for writer contention, and the main handler is registered
  // only afterwards: record a terminate request now and honour it before spawning.
  let preAdmissionCancel = null;
  const recordPreAdmissionCancel = (message) => {
    if (message?.action === "terminate") preAdmissionCancel ||= message.cause || "cancel";
  };
  process.on("message", recordPreAdmissionCancel);
  try {
    await admitWithContentionWait(() => admitToolOwner({
      scriptsDir: fileURLToPath(new URL("../../scripts/", import.meta.url)),
      input: { tool: "aidevops_bounded_operation", sessionID: operationID },
      output: { args: { action: "start", cwd: process.cwd(), command } },
      bounded: true,
    }));
  } catch (error) {
    // The admission error carries only a safe protocol reason, never host paths.
    const detail = String(error?.message || "").replace(/^BLOCKED:\s*/, "");
    process.stderr.write(`BLOCKED: bounded-operation lifecycle admission unavailable${detail ? `: ${detail}` : ""}\n`);
    return false;
  } finally {
    process.off("message", recordPreAdmissionCancel);
  }
  // A manager that went away during a contention wait can no longer supervise.
  return !(supervised && !process.connected) && !preAdmissionCancel;
}

export async function runSupervisor() {
  const config = await readPrivateConfig();
  if (!validCommand(config?.command)) return 125;
  const { command } = config;
  const operationID = String(config.operationID || "");
  if (!await admitSupervisor(command, operationID)) return 75;

  const budgetMs = boundedInteger(config.budgetMs, 15 * 60 * 1000, 10, 24 * 60 * 60 * 1000);
  const killGraceMs = boundedInteger(config.killGraceMs, 500, 10, 300 * 1000);
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
  let terminationReport = Promise.resolve();
  const reportTermination = (cause) => {
    terminationReport = sendMessage({ event: "termination", operationID, cause });
  };
  const terminator = createTerminator(tracker, killGraceMs, reportContainment, reportTermination,
    () => result.finished);
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
    env: {
      ...process.env,
      AIDEVOPS_OPERATION_ID: operationID,
      AIDEVOPS_OPERATION_OWNER_PID: String(process.pid),
      // Creation belongs to the authenticated runtime propagated by the manager,
      // not this command-scoped supervisor. Missing identity retains a coverage gap.
    },
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
    if (!terminator.terminating) reportTermination("spawn_error");
  });
  child.once("exit", (code) => {
    result.finished = true;
    result.exit = Number.isInteger(code) ? code : 1;
    // Command completion also owns cleanup of servers with detached stdio.
    // Preserve its exit status while draining any surviving owned descendants.
    const snapshot = survivorSnapshot(tracker.track(MARKER_SCAN), tracker.identity(child.pid));
    if (snapshot && (tracker.nestedTargets(snapshot).length || tracker.ownGroupMembers(snapshot) > 1)) {
      terminateSurvivors();
    }
  });

  return new Promise((resolve) => {
    const drainTimer = setInterval(() => {
      if (!result.finished || !ownedTreeDrained(tracker, terminator, terminateSurvivors, child.pid)) return;
      // A grace timer due in the same turn must not kill the reporting supervisor.
      terminator.settle();
      clearInterval(drainTimer);
      clearInterval(trackTimer);
      clearTimeout(budgetTimer);
      Promise.all([result.started, terminationReport, reportContainment()]).finally(() => resolve(result.exit));
    }, 25);
  });
}

// GH#40205 / nodejs/node#67596: on Node 26, process.exit() can deadlock joining a V8
// background compile worker parked on a main-thread GC request. The supervisor
// then sits at 0% CPU, ignores SIGTERM (its JS handler never runs) and holds the
// operation or a synchronous caller open until an outer budget. A natural exit
// disposes the isolate before the platform workers are joined, so release the
// IPC listeners that keep the channel referenced and let the loop drain. The
// unref'd fallback fires only if an unexpected handle keeps the process alive.
const FORCED_EXIT_MS = 2000;

export function exitWhenDrained(code) {
  process.exitCode = code;
  process.removeAllListeners("message");
  process.removeAllListeners("disconnect");
  if (process.connected) process.disconnect();
  setTimeout(() => process.exit(code), FORCED_EXIT_MS).unref();
}

if (isDirectEntrypoint(import.meta.url)) {
  exitWhenDrained(await runSupervisor());
}
