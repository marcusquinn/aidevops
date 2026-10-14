#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { spawn } from "node:child_process";
import { chmodSync, lstatSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { runGuardian, spawnGuardian, stopGuardian } from "./playwriter-relay-guardian.mjs";
import {
  MARKER_NAME,
  STATE_SCHEMA,
  STOP_SIGNALS,
  TERMINATE_GRACE_MS,
  hasExited,
  pause,
  removePrivateRuntime,
  terminateChild,
} from "./playwriter-relay-lifecycle.mjs";
import { reconcileOwnedRelays } from "./playwriter-relay-reconcile.mjs";

// Reviewed pin (GH#34549). Bump only after re-proving the /version, token
// challenge, loopback and telemetry opt-out contract against the release.
const PLAYWRITER_VERSION = "0.8.0";
const PLAYWRITER_PACKAGE = `playwriter@${PLAYWRITER_VERSION}`;
const RELAY_HOST = "127.0.0.1";
const RELAY_PORT = 19988;
const RELAY_ARGS = ["serve", "--host", RELAY_HOST];
const START_TIMEOUT_MS = 5_000;
const GUARDIAN_FLAG = "--aidevops-relay-guardian";
const GUARDIAN = Object.freeze({
  scriptPath: fileURLToPath(import.meta.url),
  guardianFlag: GUARDIAN_FLAG,
});
// What a stale owned relay must still match before reconciliation stops it.
const RELAY_CONTRACT = Object.freeze({
  version: PLAYWRITER_VERSION,
  port: RELAY_PORT,
  packageName: PLAYWRITER_PACKAGE,
  legacyShape: RELAY_ARGS.join(" "),
  guardianShape: GUARDIAN_FLAG,
});

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

/**
 * Stop owned relays left by earlier sessions whose supervisor died without
 * cleanup; see reconcileOwnedRelays for the ownership proof required.
 * @returns {Promise<string[]>} names of the session directories removed
 */
export function reconcileStaleRelays(parent, options = {}) {
  return reconcileOwnedRelays(parent, RELAY_CONTRACT, options);
}

async function ensureRelay(command, environment, runtime, token) {
  const existing = await probeAuthenticatedRelay({ token });
  if (existing.ready) return { child: null, owned: false };
  if (existing.reachable) {
    throw fixedError("port 19988 is occupied without matching token and version proof");
  }

  const child = spawnGuardian(GUARDIAN, command, environment, runtime);
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
    const relayCommand = validatePlaywriterCommand(argv.slice(1));
    return runGuardian(relayCommand, RELAY_ARGS, withTelemetryOptOut(environment));
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
