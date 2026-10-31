// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Shared, ref-counted sqlite3 child-process transport (GH#35702).
 * Public callers use sqlite-process.mjs; this module owns child lifecycle.
 */

import { spawn } from "node:child_process";

const SQLITE_SENTINEL = "__AIDEVOPS_QUERY_DONE__";
const SQLITE_BUSY_RE = /database is locked|SQLITE_BUSY|database table is locked/i;
const SQLITE_TIMEOUT_MS_RAW = Number.parseInt(process.env.AIDEVOPS_SQLITE_TIMEOUT_MS || "15000", 10);
export const SQLITE_TIMEOUT_MS = Number.isFinite(SQLITE_TIMEOUT_MS_RAW) && SQLITE_TIMEOUT_MS_RAW > 0
  ? SQLITE_TIMEOUT_MS_RAW
  : 15000;

// Transport state lives in a process-wide registry keyed by the canonical
// database path, so duplicate module instances (a host that imports a fresh
// plugin graph per location or reload) share one sqlite3 child instead of each
// leaving its own child blocked on stdin. Owners acquire and release it; the
// final release reaps the child. Callers that never acquire keep the historical
// lazy-spawn and force-stop semantics.
const REGISTRY_KEY = Symbol.for("aidevops.sqlite-transport.v1");
globalThis[REGISTRY_KEY] ??= { transports: new Map(), exitHooked: false };
const registry = globalThis[REGISTRY_KEY];

export function isSqliteBusyError(message) {
  return SQLITE_BUSY_RE.test(String(message || ""));
}

export function transportFor(path) {
  let transport = registry.transports.get(path);
  if (!transport) {
    transport = {
      dbPath: path,
      proc: null,
      queue: [],
      processing: false,
      currentCallback: null,
      stdoutBuffer: "",
      owners: 0,
      closeWhenIdle: false,
    };
    registry.transports.set(path, transport);
  }
  return transport;
}

/** Existing transport for a path, without creating one. */
export function existingTransport(path) {
  return registry.transports.get(path);
}

function hookProcessExit() {
  if (registry.exitHooked) return;
  registry.exitHooked = true;
  process.once("exit", () => {
    for (const transport of registry.transports.values()) stopTransport(transport);
  });
}

export function stopTransport(transport) {
  const proc = transport.proc;
  transport.proc = null;
  if (proc) {
    try {
      proc.stdin.end();
      proc.kill("SIGTERM");
    } catch {
      // Process may already be dead.
    }
  }
  transport.queue = [];
  transport.processing = false;
  transport.currentCallback = null;
  transport.stdoutBuffer = "";
  transport.closeWhenIdle = false;
}

function failPending(transport, error) {
  const callback = transport.currentCallback;
  transport.currentCallback = null;
  transport.processing = false;
  const pending = transport.queue.splice(0);
  if (callback) callback(error, "");
  for (const query of pending) query.callback(error, "");
}

function finishCurrent(transport, error, result) {
  const callback = transport.currentCallback;
  transport.currentCallback = null;
  transport.processing = false;
  if (callback) callback(error, result);
}

/**
 * Take shared ownership of a database transport.
 * @returns {() => void} idempotent release; the final release reaps sqlite3
 *   once queued writes have drained.
 */
export function acquireTransport(path) {
  const transport = transportFor(path);
  transport.owners += 1;
  transport.closeWhenIdle = false;
  let released = false;
  return () => {
    if (released) return;
    released = true;
    transport.owners = Math.max(0, transport.owners - 1);
    if (transport.owners > 0) return;
    if (transport.processing || transport.queue.length > 0) {
      transport.closeWhenIdle = true;
    } else {
      stopTransport(transport);
    }
  };
}

/** Diagnostics: live transport children and owners in this process. */
export function transportStats() {
  let children = 0;
  let owners = 0;
  for (const transport of registry.transports.values()) {
    if (transport.proc) children += 1;
    owners += transport.owners;
  }
  return { transports: registry.transports.size, children, owners };
}

// Every handler checks child identity: a late event from a superseded child
// must never clear or replace the live one.
function onStdout(transport, proc, chunk) {
  if (transport.proc !== proc) return;
  transport.stdoutBuffer += chunk.toString();
  const index = transport.stdoutBuffer.indexOf(SQLITE_SENTINEL);
  if (index === -1) return;
  const result = transport.stdoutBuffer.substring(0, index).trim();
  const endOfLine = transport.stdoutBuffer.indexOf("\n", index);
  transport.stdoutBuffer = endOfLine !== -1 ? transport.stdoutBuffer.substring(endOfLine + 1) : "";
  finishCurrent(transport, null, result);
  drainQueue(transport);
}

function onClose(transport, proc, code) {
  if (transport.proc !== proc) return;
  transport.proc = null;
  transport.stdoutBuffer = "";
  if (transport.currentCallback) finishCurrent(transport, new Error(`sqlite3 exited with code ${code}`));
  if (transport.queue.length > 0) drainQueue(transport);
}

function onError(transport, proc, error) {
  if (transport.proc !== proc) return;
  console.error(`[aidevops] SQLite process error: ${error.message}`);
  transport.proc = null;
  transport.stdoutBuffer = "";
  try { proc.kill("SIGKILL"); } catch { /* already gone */ }
  // Fail the backlog instead of respawning per queued write: a spawn or pipe
  // error repeats for every retry and would multiply children.
  failPending(transport, error);
}

function startChild(dbPath) {
  let proc;
  try {
    proc = spawn("sqlite3", ["-cmd", `.timeout ${SQLITE_TIMEOUT_MS}`, dbPath], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    // A write after the child dies raises EPIPE on stdin; the close handler
    // owns recovery, so the stream error must not become an uncaught throw.
    proc.stdin.on("error", () => {});
    proc.stdin.write(
      `PRAGMA busy_timeout=${SQLITE_TIMEOUT_MS};\nPRAGMA journal_mode=WAL;\nPRAGMA synchronous=NORMAL;\n`,
    );
    return proc;
  } catch (error) {
    console.error(`[aidevops] Failed to spawn sqlite3: ${error.message}`);
    try { proc?.kill("SIGKILL"); } catch { /* not started */ }
    return null;
  }
}

function spawnSqlite(transport) {
  if (transport.proc) return;
  const proc = startChild(transport.dbPath);
  if (!proc) return;
  transport.proc = proc;
  hookProcessExit();
  proc.stdout.on("data", (chunk) => onStdout(transport, proc, chunk));
  proc.stderr.on("data", (chunk) => {
    const message = chunk.toString().trim();
    if (message && !isSqliteBusyError(message)) console.error(`[aidevops] SQLite: ${message}`);
  });
  proc.on("close", (code) => onClose(transport, proc, code));
  proc.on("error", (error) => onError(transport, proc, error));
}

export function drainQueue(transport) {
  if (transport.processing) return;
  if (transport.queue.length === 0) {
    if (transport.closeWhenIdle && transport.owners === 0) stopTransport(transport);
    return;
  }
  spawnSqlite(transport);
  if (!transport.proc) {
    failPending(transport, new Error("sqlite3 process unavailable"));
    return;
  }

  transport.processing = true;
  const { sql, callback } = transport.queue.shift();
  transport.currentCallback = callback;
  try {
    transport.proc.stdin.write(`${sql}\nSELECT '${SQLITE_SENTINEL}';\n`);
  } catch (error) {
    finishCurrent(transport, error, "");
    drainQueue(transport);
  }
}
