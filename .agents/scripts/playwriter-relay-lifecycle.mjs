// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Process lifecycle primitives for playwriter-authenticated-relay.mjs
// (GH#34615): signalling, bounded waits, process-group teardown, and the
// marker-verified private runtime-directory layout.

import { existsSync, lstatSync, readFileSync, rmSync } from "node:fs";

// MCP hosts allow ~2s after stdin closes before signalling, so the whole owned
// teardown must fit well inside that window.
export const TERMINATE_GRACE_MS = 1_000;
const KILL_SETTLE_MS = 1_000;
export const STOP_SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"];
export const POSIX_GROUPS = process.platform !== "win32";
export const STATE_SCHEMA = "aidevops-playwriter-relay/v2";
export const MARKER_NAME = ".aidevops-owned-relay";

function lifecycleError(message) {
  return new Error(`Authenticated Playwriter relay: ${message}`);
}

export function cleanupPrivateRuntime(runtime) {
  const stats = lstatSync(runtime.directory);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw lifecycleError("refusing cleanup of a non-regular runtime directory");
  }
  if (readFileSync(runtime.markerPath, "utf8") !== runtime.ownerToken) {
    throw lifecycleError("refusing cleanup without matching ownership evidence");
  }
  rmSync(runtime.directory, { recursive: true, force: false });
}

// The supervisor and its relay guardian may both reach cleanup; whichever is
// second finds the directory already gone.
export function removePrivateRuntime(runtime) {
  if (!runtime || !existsSync(runtime.directory)) return;
  try {
    cleanupPrivateRuntime(runtime);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

export const pause = (milliseconds) => new Promise((resolvePromise) => {
  setTimeout(resolvePromise, milliseconds);
});

export function hasExited(child) {
  return child.exitCode !== null || child.signalCode !== null;
}

// Resolves true on exit, false on timeout. The timer is always cleared so a
// finished child never keeps the supervisor alive past the host's grace.
export function waitForExit(child, timeoutMs) {
  if (hasExited(child)) return Promise.resolve(true);
  return new Promise((resolvePromise) => {
    const onExit = () => {
      clearTimeout(timer);
      resolvePromise(true);
    };
    const timer = setTimeout(() => {
      child.off("exit", onExit);
      resolvePromise(hasExited(child));
    }, timeoutMs);
    child.once("exit", onExit);
  });
}

async function waitUntil(predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await pause(50);
  }
  return predicate();
}

export function sendSignal(target, signal) {
  try {
    process.kill(target, signal);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    throw error;
  }
}

export function processAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

export function processGroupAlive(groupId) {
  return processAlive(-groupId);
}

/**
 * Stop every member of an owned process group: SIGTERM, a bounded wait, then
 * SIGKILL. Package runners (`npm exec`, `bun x`) keep the real relay as a
 * descendant, so signalling only the runner PID can orphan the listener.
 * @returns {Promise<boolean>} true once no member of the group remains
 */
export async function terminateProcessGroup(groupId, { graceMs = TERMINATE_GRACE_MS } = {}) {
  if (!POSIX_GROUPS) throw lifecycleError("process-group termination requires a POSIX platform");
  if (!Number.isInteger(groupId) || groupId <= 1 || groupId === process.pid) {
    throw lifecycleError("refusing to signal an invalid process group");
  }
  if (!sendSignal(-groupId, "SIGTERM")) return true;
  if (await waitUntil(() => !processGroupAlive(groupId), graceMs)) return true;
  sendSignal(-groupId, "SIGKILL");
  return waitUntil(() => !processGroupAlive(groupId), KILL_SETTLE_MS);
}

export async function terminateChild(child) {
  if (!child || hasExited(child)) return;
  child.kill("SIGTERM");
  if (await waitForExit(child, TERMINATE_GRACE_MS)) return;
  child.kill("SIGKILL");
  await waitForExit(child, KILL_SETTLE_MS);
}

