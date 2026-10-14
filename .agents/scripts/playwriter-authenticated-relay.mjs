#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { spawn, spawnSync } from "node:child_process";
import {
  chmodSync,
  closeSync,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

// Reviewed pin (GH#34549). Bump only after re-proving the /version, token
// challenge, loopback and telemetry opt-out contract against the release.
const PLAYWRITER_VERSION = "0.8.0";
const PLAYWRITER_PACKAGE = `playwriter@${PLAYWRITER_VERSION}`;
const RELAY_HOST = "127.0.0.1";
const RELAY_PORT = 19988;
const RELAY_ARGS = ["serve", "--host", RELAY_HOST];
const START_TIMEOUT_MS = 5_000;
// GH#34615: MCP hosts allow ~2s after stdin closes before signalling, so the
// whole owned teardown must fit well inside that window.
const TERMINATE_GRACE_MS = 1_000;
const KILL_SETTLE_MS = 1_000;
const GUARDIAN_STOP_MS = 3_000;
const STOP_SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"];
const GUARDIAN_FLAG = "--aidevops-relay-guardian";
const STATE_SCHEMA = "aidevops-playwriter-relay/v2";
const LEGACY_STATE_SCHEMA = "aidevops-playwriter-relay/v1";
const MARKER_NAME = ".aidevops-owned-relay";
const SESSION_DIRECTORY = /^session-(\d+)-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const POSIX_GROUPS = process.platform !== "win32";
const SCRIPT_PATH = fileURLToPath(import.meta.url);

function fixedError(message) {
  return new Error(`Authenticated Playwriter relay: ${message}`);
}

export function validatePlaywriterCommand(command) {
  if (!Array.isArray(command) || command.some((part) => typeof part !== "string" || !part)) {
    throw fixedError("invalid package-runner command");
  }
  const runner = basename(command[0]);
  const args = command.slice(1);
  const npxShape = runner === "npx"
    && (args.length === 1 || (args.length === 2 && args[0] === "-y"))
    && args.at(-1) === PLAYWRITER_PACKAGE;
  const bunShape = runner === "bun"
    && args.length === 2
    && args[0] === "x"
    && args[1] === PLAYWRITER_PACKAGE;
  if (!npxShape && !bunShape) {
    throw fixedError("command is not the reviewed Playwriter package shape");
  }
  return [...command];
}

/**
 * Playwriter >= 0.8.0 relays send anonymous usage telemetry unless opted out.
 * Default it off before any relay or MCP process starts; an operator who set
 * PLAYWRITER_TELEMETRY explicitly keeps that choice.
 */
export function withTelemetryOptOut(environment) {
  if (environment.PLAYWRITER_TELEMETRY !== undefined) return { ...environment };
  return {
    ...environment,
    PLAYWRITER_TELEMETRY: "0",
    DO_NOT_TRACK: environment.DO_NOT_TRACK ?? "1",
  };
}

function requireToken(environment) {
  const token = environment.PLAYWRITER_TOKEN;
  if (typeof token !== "string" || token.length < 32) {
    throw fixedError("PLAYWRITER_TOKEN must be injected through the environment and contain at least 32 characters");
  }
  return token;
}

function privateDirectory(path) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  const stats = lstatSync(path);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw fixedError("private runtime path is not a regular directory");
  }
  chmodSync(path, 0o700);
}

export function privateRuntimeParent(tempRoot) {
  if (!isAbsolute(tempRoot)) throw fixedError("AIDEVOPS_TEMP_DIR must be absolute");
  privateDirectory(tempRoot);
  const physicalTempRoot = realpathSync(tempRoot);
  const parent = resolve(tempRoot, "mcp", "playwriter", "authenticated-relay");
  privateDirectory(parent);
  const physicalParent = realpathSync(parent);
  const relativeParent = relative(physicalTempRoot, physicalParent);
  if (relativeParent.startsWith("..") || isAbsolute(relativeParent)) {
    throw fixedError("private runtime path escapes AIDEVOPS_TEMP_DIR");
  }
  return physicalParent;
}

export function createPrivateRuntime(tempRoot, ownerToken = randomUUID()) {
  const physicalParent = privateRuntimeParent(tempRoot);
  const directory = join(physicalParent, `session-${process.pid}-${randomUUID()}`);
  mkdirSync(directory, { mode: 0o700 });
  const markerPath = join(directory, MARKER_NAME);
  writeFileSync(markerPath, ownerToken, { flag: "wx", mode: 0o600 });
  return {
    directory,
    markerPath,
    ownerToken,
    logPath: join(directory, "relay.log"),
    statePath: join(directory, "state.json"),
  };
}

export function cleanupPrivateRuntime(runtime) {
  const stats = lstatSync(runtime.directory);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw fixedError("refusing cleanup of a non-regular runtime directory");
  }
  if (readFileSync(runtime.markerPath, "utf8") !== runtime.ownerToken) {
    throw fixedError("refusing cleanup without matching ownership evidence");
  }
  rmSync(runtime.directory, { recursive: true, force: false });
}

// The supervisor and its relay guardian may both reach cleanup; whichever is
// second finds the directory already gone.
function removePrivateRuntime(runtime) {
  if (!runtime || !existsSync(runtime.directory)) return;
  try {
    cleanupPrivateRuntime(runtime);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

function runtimeFromMessage(message) {
  if (message?.type !== "runtime") return null;
  const { directory, markerPath, ownerToken } = message;
  if (typeof directory !== "string" || !isAbsolute(directory)) return null;
  if (typeof ownerToken !== "string" || !ownerToken) return null;
  if (markerPath !== join(directory, MARKER_NAME)) return null;
  return { directory, markerPath, ownerToken };
}

function relayUrl(path, port = RELAY_PORT) {
  return `http://${RELAY_HOST}:${port}${path}`;
}

async function boundedFetch(fetchImpl, url, options = {}) {
  return fetchImpl(url, {
    ...options,
    redirect: "error",
    signal: AbortSignal.timeout(1_000),
  });
}

export async function probeAuthenticatedRelay({
  token,
  port = RELAY_PORT,
  fetchImpl = fetch,
} = {}) {
  try {
    const versionResponse = await boundedFetch(fetchImpl, relayUrl("/version", port));
    if (!versionResponse.ok) return { reachable: true, ready: false };
    const versionPayload = await versionResponse.json();
    if (versionPayload?.version !== PLAYWRITER_VERSION) return { reachable: true, ready: false };

    const wrongToken = randomUUID();
    const wrongResponse = await boundedFetch(
      fetchImpl,
      relayUrl(`/cdp/aidevops-proof?token=${encodeURIComponent(wrongToken)}`, port),
    );
    const rightResponse = await boundedFetch(
      fetchImpl,
      relayUrl(`/cdp/aidevops-proof?token=${encodeURIComponent(token)}`, port),
    );
    return {
      reachable: true,
      ready: wrongResponse.status === 401 && rightResponse.status === 404,
    };
  } catch {
    return { reachable: false, ready: false };
  }
}

const pause = (milliseconds) => new Promise((resolvePromise) => {
  setTimeout(resolvePromise, milliseconds);
});

function hasExited(child) {
  return child.exitCode !== null || child.signalCode !== null;
}

// Resolves true on exit, false on timeout. The timer is always cleared so a
// finished child never keeps the supervisor alive past the host's grace.
function waitForExit(child, timeoutMs) {
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

function sendSignal(target, signal) {
  try {
    process.kill(target, signal);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    throw error;
  }
}

function processAlive(pid) {
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
  if (!POSIX_GROUPS) throw fixedError("process-group termination requires a POSIX platform");
  if (!Number.isInteger(groupId) || groupId <= 1 || groupId === process.pid) {
    throw fixedError("refusing to signal an invalid process group");
  }
  if (!sendSignal(-groupId, "SIGTERM")) return true;
  if (await waitUntil(() => !processGroupAlive(groupId), graceMs)) return true;
  sendSignal(-groupId, "SIGKILL");
  return waitUntil(() => !processGroupAlive(groupId), KILL_SETTLE_MS);
}

async function terminateChild(child) {
  if (!child || hasExited(child)) return;
  child.kill("SIGTERM");
  if (await waitForExit(child, TERMINATE_GRACE_MS)) return;
  child.kill("SIGKILL");
  await waitForExit(child, KILL_SETTLE_MS);
}

/**
 * Start the relay under a guardian process. The guardian leads its own process
 * group, so host group signals cannot kill it before cleanup, and it holds an
 * IPC channel to this supervisor. When that channel closes for any reason,
 * including SIGKILL of the supervisor, the guardian stops the whole relay group
 * and removes the private runtime.
 */
function spawnGuardian(command, environment, runtime) {
  const logDescriptor = openSync(runtime.logPath, "a", 0o600);
  chmodSync(runtime.logPath, 0o600);
  try {
    const guardian = spawn(process.execPath, [SCRIPT_PATH, GUARDIAN_FLAG, ...command], {
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

async function stopGuardian(guardian) {
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

async function waitForRelay(token, child) {
  const deadline = Date.now() + START_TIMEOUT_MS;
  do {
    const proof = await probeAuthenticatedRelay({ token });
    if (proof.ready) return proof;
    if (proof.reachable || child.spawnFailed || hasExited(child)) return proof;
    await pause(100);
  } while (Date.now() < deadline);
  return { reachable: false, ready: false };
}

function guardianExitCode(relay) {
  if (relay.exitCode !== null) return relay.exitCode;
  return relay.signalCode ? 1 : 0;
}

async function runGuardian(command, environment) {
  if (typeof process.send !== "function") {
    throw fixedError("relay guardian requires a supervisor IPC channel");
  }
  let runtime = null;
  process.on("message", (message) => {
    runtime = runtimeFromMessage(message) ?? runtime;
  });
  const relay = spawn(command[0], [...command.slice(1), ...RELAY_ARGS], {
    env: environment,
    shell: false,
    stdio: ["ignore", "inherit", "inherit"],
  });
  let stopping = null;
  const stop = () => (stopping ??= (async () => {
    // The guardian leads this group; its own SIGTERM is absorbed by the
    // handlers below, so one group signal reaches every relay descendant.
    if (POSIX_GROUPS) sendSignal(-process.pid, "SIGTERM");
    else if (!hasExited(relay)) relay.kill("SIGTERM");
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
    if (POSIX_GROUPS) sendSignal(-process.pid, "SIGKILL");
    else if (!hasExited(relay)) relay.kill("SIGKILL");
    process.exit(code);
  })());
  for (const signal of STOP_SIGNALS) process.on(signal, () => { void stop(); });
  process.once("disconnect", () => { void stop(); });
  relay.once("error", () => { void stop(); });
  relay.once("exit", () => { void stop(); });
  return new Promise(() => {});
}

function inspectProcess(pid) {
  const result = spawnSync("ps", ["-o", "pgid=", "-o", "command=", "-p", String(pid)], {
    encoding: "utf8",
    shell: false,
    timeout: 2_000,
  });
  const match = result.status === 0 ? /^\s*(\d+)\s+([\s\S]+)$/.exec(result.stdout.trim()) : null;
  return match ? { groupId: Number(match[1]), command: match[2] } : null;
}

function readSessionState(directory, sessionPid) {
  const stats = lstatSync(directory);
  if (!stats.isDirectory() || stats.isSymbolicLink()) return null;
  const marker = lstatSync(join(directory, MARKER_NAME), { throwIfNoEntry: false });
  if (!marker?.isFile() || marker.isSymbolicLink()) return null;
  const statePath = join(directory, "state.json");
  const stateStats = lstatSync(statePath, { throwIfNoEntry: false });
  if (!stateStats) return { supervisorPid: sessionPid, owned: false };
  if (!stateStats.isFile() || stateStats.isSymbolicLink()) return null;
  try {
    const state = JSON.parse(readFileSync(statePath, "utf8"));
    if (![STATE_SCHEMA, LEGACY_STATE_SCHEMA].includes(state?.schema)) return null;
    return state.supervisorPid === sessionPid ? state : null;
  } catch {
    return null;
  }
}

/**
 * Locate the process group of an owned relay whose supervisor is gone.
 * Returns null when nothing is left to stop and undefined when ownership
 * cannot be proven, in which case the relay and its state are left alone.
 */
function staleRelayGroup(state, inspect) {
  const legacy = state.schema === LEGACY_STATE_SCHEMA;
  // v1 relays shared the supervisor's group; v2 relays lead a guardian group.
  const groupId = legacy ? state.supervisorPid : state.relayGroupId;
  const leaderPid = legacy ? state.relayPid : state.relayGroupId;
  if (!Number.isInteger(groupId) || !Number.isInteger(leaderPid) || groupId <= 1) return undefined;
  if (state.version !== PLAYWRITER_VERSION || state.port !== RELAY_PORT) return undefined;
  if (!processGroupAlive(groupId)) return null;
  const leader = inspect(leaderPid);
  if (!leader || leader.groupId !== groupId || !leader.command.includes(PLAYWRITER_PACKAGE)) {
    return undefined;
  }
  const shape = legacy ? RELAY_ARGS.join(" ") : GUARDIAN_FLAG;
  return leader.command.includes(shape) ? groupId : undefined;
}

/**
 * Stop relays this launcher started in an earlier session whose supervisor
 * died without cleanup, then remove that session's private state. A relay is
 * stopped only with marker-protected state, a dead supervisor, and a live
 * process group whose leader matches the reviewed relay command; a listener
 * on the relay port is never enough.
 * @returns {Promise<string[]>} names of the session directories removed
 */
export async function reconcileStaleRelays(parent, { inspect = inspectProcess } = {}) {
  if (!POSIX_GROUPS || !existsSync(parent)) return [];
  const removed = [];
  for (const name of readdirSync(parent)) {
    const match = SESSION_DIRECTORY.exec(name);
    if (!match) continue;
    const directory = join(parent, name);
    try {
      const state = readSessionState(directory, Number(match[1]));
      if (!state || processAlive(state.supervisorPid)) continue;
      const groupId = state.owned ? staleRelayGroup(state, inspect) : null;
      if (groupId === undefined) continue;
      if (groupId !== null && !(await terminateProcessGroup(groupId))) continue;
      rmSync(directory, { recursive: true, force: true });
      removed.push(name);
    } catch {
      // One unreadable session must not block a new relay start.
    }
  }
  return removed;
}

async function ensureRelay(command, environment, runtime, token) {
  const existing = await probeAuthenticatedRelay({ token });
  if (existing.ready) return { child: null, owned: false };
  if (existing.reachable) {
    throw fixedError("port 19988 is occupied without matching token and version proof");
  }

  const child = spawnGuardian(command, environment, runtime);
  const proof = await waitForRelay(token, child);
  if (!proof.ready) {
    await stopGuardian(child);
    throw fixedError("could not prove the localhost relay version and token contract");
  }
  if (hasExited(child) || child.spawnFailed) {
    // Another relay won the port race; this guardian has already exited.
    return { child: null, owned: false };
  }
  return { child, owned: true };
}

function writeState(runtime, relay) {
  const state = {
    schema: STATE_SCHEMA,
    host: RELAY_HOST,
    port: RELAY_PORT,
    version: PLAYWRITER_VERSION,
    supervisorPid: process.pid,
    relayGroupId: relay.owned ? relay.child.pid : null,
    owned: relay.owned,
  };
  writeFileSync(runtime.statePath, `${JSON.stringify(state)}\n`, { flag: "wx", mode: 0o600 });
}

async function supervise(command, environment) {
  const token = requireToken(environment);
  const tempRoot = environment.AIDEVOPS_TEMP_DIR
    || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  await reconcileStaleRelays(privateRuntimeParent(tempRoot));
  const runtime = createPrivateRuntime(tempRoot);
  let relay = null;
  let mcp = null;
  let stopping = false;
  // GH#34615: persistent handlers for every stop signal. With `once`, a
  // repeated SIGTERM fell through to Node's default action and killed the
  // supervisor before `finally`, leaving the owned relay running.
  // Absorbing repeats must not hang shutdown, so the first stop signal also
  // arms one bounded SIGKILL escalation for an MCP child that ignores it.
  let escalation = null;
  const onStopSignal = (signal) => {
    stopping = true;
    if (!mcp || hasExited(mcp)) return;
    mcp.kill(signal === "SIGHUP" ? "SIGTERM" : signal);
    escalation ??= setTimeout(() => {
      if (!hasExited(mcp)) mcp.kill("SIGKILL");
    }, TERMINATE_GRACE_MS);
    escalation.unref();
  };
  const handlers = STOP_SIGNALS.map((signal) => [signal, () => onStopSignal(signal)]);
  for (const [signal, handler] of handlers) process.on(signal, handler);
  try {
    relay = await ensureRelay(command, environment, runtime, token);
    writeState(runtime, relay);
    if (stopping) return 1;
    mcp = spawn(command[0], command.slice(1), {
      env: {
        ...environment,
        PLAYWRITER_HOST: RELAY_HOST,
      },
      shell: false,
      stdio: "inherit",
    });

    if (relay.owned) {
      relay.child.once("exit", () => {
        if (!stopping && mcp && !hasExited(mcp)) mcp.kill("SIGTERM");
      });
    }

    const result = await new Promise((resolvePromise) => {
      mcp.once("error", () => resolvePromise({ code: 1, signal: null }));
      mcp.once("exit", (code, signal) => resolvePromise({ code, signal }));
    });
    stopping = true;
    return result.code ?? (result.signal ? 1 : 0);
  } finally {
    stopping = true;
    await Promise.all([
      terminateChild(mcp),
      relay?.owned ? stopGuardian(relay.child) : Promise.resolve(),
    ]);
    // Synchronous from here on, so no signal can interleave with cleanup.
    for (const [signal, handler] of handlers) process.off(signal, handler);
    removePrivateRuntime(runtime);
  }
}

export async function main(argv = process.argv.slice(2), environment = process.env) {
  if (environment.AIDEVOPS_PLAYWRITER_AUTHENTICATED_RELAY !== "1") {
    throw fixedError("opt-in environment flag is not enabled");
  }
  if (argv[0] === GUARDIAN_FLAG) {
    return runGuardian(validatePlaywriterCommand(argv.slice(1)), withTelemetryOptOut(environment));
  }
  const command = validatePlaywriterCommand(argv);
  return supervise(command, withTelemetryOptOut(environment));
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath && fileURLToPath(import.meta.url) === invokedPath) {
  main()
    .then((code) => { process.exitCode = code; })
    .catch((error) => {
      process.stderr.write(`${error instanceof Error ? error.message : "Authenticated Playwriter relay failed"}\n`);
      process.exitCode = 1;
    });
}
