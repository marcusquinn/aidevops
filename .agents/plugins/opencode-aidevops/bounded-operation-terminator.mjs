// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { signalEach } from "./bounded-operation-process-tree.mjs";

export const MARKER_SCAN = Object.freeze({ markers: true });

function signalOwnGroup(signal) {
  try {
    process.kill(-process.pid, signal);
    return true;
  } catch {
    // The group may already contain only this supervisor.
    return false;
  }
}

// After the command has exited, the self-inclusive group SIGKILL waits this long
// for the drain to report its status. It only bounds survivors that outlive SIGKILL.
const EXITED_COMMAND_BACKSTOP_MS = 10_000;

// Signals nested helper groups before and after the grace period, then the
// supervisor's own group. Containment is reported before the final SIGKILL.
// GH#40309: on a loaded host a command can exit inside its grace while the
// drain's process scans are still running when the grace timer fires; killing
// the supervisor then turned a clean exit-0 timeout into an unknown exit.
export function createTerminator(tracker, killGraceMs, reportContainment, reportTermination, commandExited) {
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
  // status; the group SIGKILL stays as the backstop for anything that outlives
  // SIGKILL or an inventory that stays unavailable (the drain loop retries it).
  const containOwnGroup = () => {
    if (!commandExited()) return killGroup();
    tracker.killOwnGroupOthers();
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
