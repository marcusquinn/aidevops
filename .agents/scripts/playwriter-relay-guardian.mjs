// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Relay guardian for playwriter-authenticated-relay.mjs (GH#34615). The
// guardian leads its own process group, so host group signals cannot kill it
// before cleanup, and holds an IPC channel to the supervisor. When that channel
// closes for any reason, including SIGKILL of the supervisor, the guardian
// stops the whole relay group and removes the private runtime.

import { spawn } from "node:child_process";
import { chmodSync, closeSync, openSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import {
  MARKER_NAME,
  POSIX_GROUPS,
  STOP_SIGNALS,
  TERMINATE_GRACE_MS,
  hasExited,
  removePrivateRuntime,
  sendSignal,
  terminateProcessGroup,
  waitForExit,
} from "./playwriter-relay-lifecycle.mjs";

const GUARDIAN_STOP_MS = 3_000;

/**
 * Start `node <scriptPath> <guardianFlag> <command...>` as the relay guardian
 * and hand it the private runtime over IPC (never through argv or env).
 */
export function spawnGuardian({ scriptPath, guardianFlag }, command, environment, runtime) {
  const logDescriptor = openSync(runtime.logPath, "a", 0o600);
  chmodSync(runtime.logPath, 0o600);
  try {
    const guardian = spawn(process.execPath, [scriptPath, guardianFlag, ...command], {
      env: environment,
      shell: false,
      detached: POSIX_GROUPS,
      stdio: ["ignore", logDescriptor, logDescriptor, "ipc"],
    });
    guardian.spawnFailed = false;
    guardian.once("error", () => { guardian.spawnFailed = true; });
    guardian.send(
      {
        type: "runtime",
        directory: runtime.directory,
        markerPath: runtime.markerPath,
        ownerToken: runtime.ownerToken,
      },
      () => {},
    );
    return guardian;
  } finally {
    closeSync(logDescriptor);
  }
}

export async function stopGuardian(guardian) {
  // An exited guardian has already SIGKILLed its own group; its reaped PID is
  // never signalled again because it may belong to an unrelated process.
  if (!guardian || hasExited(guardian)) return;
  if (guardian.connected) guardian.disconnect();
  else guardian.kill("SIGTERM");
  if (await waitForExit(guardian, GUARDIAN_STOP_MS)) return;
  // Still our unreaped child, so its PID and group are still ours to stop.
  if (POSIX_GROUPS && guardian.pid) await terminateProcessGroup(guardian.pid);
  else guardian.kill("SIGKILL");
}

function runtimeFromMessage(message) {
  if (message?.type !== "runtime") return null;
  const { directory, markerPath, ownerToken } = message;
  if (typeof directory !== "string" || !isAbsolute(directory)) return null;
  if (typeof ownerToken !== "string" || !ownerToken) return null;
  return markerPath === join(directory, MARKER_NAME) ? { directory, markerPath, ownerToken } : null;
}

function guardianExitCode(relay) {
  if (relay.exitCode !== null) return relay.exitCode;
  return relay.signalCode ? 1 : 0;
}

function signalRelay(relay, signal) {
  // The guardian leads this group; its own SIGTERM is absorbed by the stop
  // handlers, so one group signal reaches every relay descendant.
  if (POSIX_GROUPS) sendSignal(-process.pid, signal);
  else if (!hasExited(relay)) relay.kill(signal);
}

/** Guardian entry point; runs until the relay or the supervisor goes away. */
export async function runGuardian(command, relayArgs, environment) {
  if (typeof process.send !== "function") {
    throw new Error("Authenticated Playwriter relay: relay guardian requires a supervisor IPC channel");
  }
  let runtime = null;
  process.on("message", (message) => {
    runtime = runtimeFromMessage(message) ?? runtime;
  });
  const relay = spawn(command[0], [...command.slice(1), ...relayArgs], {
    env: environment,
    shell: false,
    stdio: ["ignore", "inherit", "inherit"],
  });
  let stopping = null;
  const stop = () => (stopping ??= (async () => {
    signalRelay(relay, "SIGTERM");
    await waitForExit(relay, TERMINATE_GRACE_MS);
    // A connected supervisor still owns its runtime (for example after losing
    // a port race); only clean up on its behalf once the channel is gone.
    if (!process.connected) {
      try {
        removePrivateRuntime(runtime);
      } catch {
        // Ownership mismatch: leave the directory for marker-verified cleanup.
      }
    }
    const code = guardianExitCode(relay);
    signalRelay(relay, "SIGKILL");
    process.exit(code);
  })());
  for (const signal of STOP_SIGNALS) process.on(signal, () => { void stop(); });
  process.once("disconnect", () => { void stop(); });
  relay.once("error", () => { void stop(); });
  relay.once("exit", () => { void stop(); });
  return new Promise(() => {});
}
