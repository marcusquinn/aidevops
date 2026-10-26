// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Runtime-neutral sqlite3 process transport shared by scripts and plugins. */

import { execFileSync, spawn } from "node:child_process";
import { existsSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";

const SQLITE_SENTINEL = "__AIDEVOPS_QUERY_DONE__";
const SQLITE_BUSY_RE = /database is locked|SQLITE_BUSY|database table is locked/i;
const SQLITE_QUEUE_MAX = Number.parseInt(process.env.AIDEVOPS_SQLITE_QUEUE_MAX || "1000", 10);
const SQLITE_TIMEOUT_MS_RAW = Number.parseInt(process.env.AIDEVOPS_SQLITE_TIMEOUT_MS || "15000", 10);
const SQLITE_TIMEOUT_MS = Number.isFinite(SQLITE_TIMEOUT_MS_RAW) && SQLITE_TIMEOUT_MS_RAW > 0
  ? SQLITE_TIMEOUT_MS_RAW
  : 15000;

// GH#35702: transport state lives in a process-wide registry keyed by the
// canonical database path, so duplicate module instances (a host that imports
// a fresh plugin graph per location or reload) share one sqlite3 child instead
// of each leaving its own child blocked on stdin. Owners acquire and release
// it; the final release reaps the child. CLI callers that never acquire keep
// the historical lazy-spawn and shutdownSqlite() semantics.
const REGISTRY_KEY = Symbol.for("aidevops.sqlite-transport.v1");
const registry = globalThis[REGISTRY_KEY] ??= { transports: new Map(), exitHooked: false };

let dbPath = "";

function transportFor(path) {
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

function hookProcessExit() {
  if (registry.exitHooked) return;
  registry.exitHooked = true;
  process.once("exit", () => {
    for (const transport of registry.transports.values()) stopTransport(transport);
  });
}

function stopTransport(transport) {
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

/** Validate and canonicalise a database path without interpreting it as shell input. */
export function canonicalizeSqliteDbPath(value) {
  if (typeof value !== "string" || value.trim() !== value || !value || value.includes("\0")) {
    throw new TypeError("SQLite database path must be a non-empty canonical string");
  }
  if (/^[a-z][a-z0-9+.-]*:/i.test(value) || !isAbsolute(value)) {
    throw new TypeError("SQLite database path must be an absolute filesystem path");
  }

  const normalized = resolve(value);
  if (existsSync(normalized)) {
    if (!statSync(normalized).isFile()) throw new TypeError("SQLite database path must name a file");
    return realpathSync(normalized);
  }

  const missingParts = [];
  let ancestor = normalized;
  while (!existsSync(ancestor)) {
    missingParts.unshift(basename(ancestor));
    const parent = dirname(ancestor);
    if (parent === ancestor) break;
    ancestor = parent;
  }
  return join(realpathSync(ancestor), ...missingParts);
}

/**
 * Set the database path before operations. Changing it shuts down the old
 * path's process unless another module instance still owns it.
 */
export function setDbPath(value) {
  const canonical = canonicalizeSqliteDbPath(value);
  if (dbPath && dbPath !== canonical) {
    const previous = registry.transports.get(dbPath);
    if (previous && previous.owners === 0) stopTransport(previous);
  }
  dbPath = canonical;
  return dbPath;
}

/**
 * Take shared ownership of the transport for the configured database.
 * @returns {() => void} idempotent release; the final release reaps sqlite3
 *   once queued writes have drained.
 */
export function acquireSqlite() {
  const transport = transportFor(getDbPath());
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
      return;
    }
    stopTransport(transport);
  };
}

/** Diagnostics: live transport children and owners in this process. */
export function sqliteTransportStats() {
  let children = 0;
  let owners = 0;
  for (const transport of registry.transports.values()) {
    if (transport.proc) children += 1;
    owners += transport.owners;
  }
  return { transports: registry.transports.size, children, owners };
}

export function getDbPath() {
  if (!dbPath) throw new Error("SQLite database path has not been configured");
  return dbPath;
}

export function sqliteAvailable() {
  try {
    execFileSync("sqlite3", ["-version"], {
      encoding: "utf8",
      stdio: ["ignore", "ignore", "ignore"],
      timeout: 2000,
    });
    return true;
  } catch {
    return false;
  }
}

function spawnSqlite(transport) {
  if (transport.proc) return;

  let proc;
  try {
    proc = spawn("sqlite3", ["-cmd", `.timeout ${SQLITE_TIMEOUT_MS}`, transport.dbPath], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    // A write after the child dies raises EPIPE on stdin; the close handler
    // owns recovery, so the stream error must not become an uncaught throw.
    proc.stdin.on("error", () => {});
    proc.stdin.write(
      `PRAGMA busy_timeout=${SQLITE_TIMEOUT_MS};\nPRAGMA journal_mode=WAL;\nPRAGMA synchronous=NORMAL;\n`,
    );
  } catch (error) {
    console.error(`[aidevops] Failed to spawn sqlite3: ${error.message}`);
    try { proc?.kill("SIGKILL"); } catch { /* not started */ }
    return;
  }
  transport.proc = proc;
  hookProcessExit();

  // GH#35702: every handler checks child identity. A late event from a
  // superseded child must never clear or replace the live one.
  proc.stdout.on("data", (chunk) => {
    if (transport.proc !== proc) return;
    transport.stdoutBuffer += chunk.toString();
    const index = transport.stdoutBuffer.indexOf(SQLITE_SENTINEL);
    if (index === -1) return;

    const result = transport.stdoutBuffer.substring(0, index).trim();
    const endOfLine = transport.stdoutBuffer.indexOf("\n", index);
    transport.stdoutBuffer = endOfLine !== -1 ? transport.stdoutBuffer.substring(endOfLine + 1) : "";
    const callback = transport.currentCallback;
    transport.currentCallback = null;
    transport.processing = false;
    if (callback) callback(null, result);
    drainQueue(transport);
  });

  proc.stderr.on("data", (chunk) => {
    const message = chunk.toString().trim();
    if (message && !isSqliteBusyError(message)) console.error(`[aidevops] SQLite: ${message}`);
  });

  proc.on("close", (code) => {
    if (transport.proc !== proc) return;
    transport.proc = null;
    transport.stdoutBuffer = "";
    if (transport.currentCallback) {
      const callback = transport.currentCallback;
      transport.currentCallback = null;
      transport.processing = false;
      callback(new Error(`sqlite3 exited with code ${code}`));
    }
    if (transport.queue.length > 0) drainQueue(transport);
  });

  proc.on("error", (error) => {
    if (transport.proc !== proc) return;
    console.error(`[aidevops] SQLite process error: ${error.message}`);
    transport.proc = null;
    transport.stdoutBuffer = "";
    try { proc.kill("SIGKILL"); } catch { /* already gone */ }
    // Fail the backlog instead of respawning per queued write: a spawn or
    // pipe error repeats for every retry and would multiply children.
    failPending(transport, error);
  });
}

function drainQueue(transport) {
  if (transport.processing) return;
  if (transport.queue.length === 0) {
    if (transport.closeWhenIdle && transport.owners === 0) stopTransport(transport);
    return;
  }
  if (!transport.proc) spawnSqlite(transport);
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
    transport.processing = false;
    transport.currentCallback = null;
    callback(error, "");
    drainQueue(transport);
  }
}

export function sqliteExec(sql) {
  const queueMax = Number.isFinite(SQLITE_QUEUE_MAX) && SQLITE_QUEUE_MAX > 0 ? SQLITE_QUEUE_MAX : 1000;
  const transport = transportFor(getDbPath());
  if (transport.queue.length >= queueMax) {
    if (process.env.AIDEVOPS_SQLITE_QUEUE_WARN !== "0") {
      console.error(`[aidevops] SQLite async queue full (${queueMax}); dropping observability write`);
    }
    return false;
  }
  transport.queue.push({
    sql,
    callback: (error) => {
      if (error && !isSqliteBusyError(error.message)) {
        console.error(`[aidevops] SQLite async exec failed: ${error.message}`);
      }
    },
  });
  drainQueue(transport);
  return true;
}

export function sqliteExecSync(sql, timeout = 5000) {
  try {
    return execFileSync("sqlite3", ["-cmd", `.timeout ${SQLITE_TIMEOUT_MS}`, getDbPath()], {
      input: sql,
      encoding: "utf8",
      timeout,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (error) {
    console.error(`[aidevops] SQLite sync exec failed: ${error.stderr || error.message}`);
    return null;
  }
}

export function isSqliteBusyError(message) {
  return SQLITE_BUSY_RE.test(String(message || ""));
}

/** Force-stop the configured database's transport (tests, CLI teardown). */
export function shutdownSqlite() {
  if (!dbPath) return;
  const transport = registry.transports.get(dbPath);
  if (transport) stopTransport(transport);
}

export function sqlEscape(value) {
  if (value === null || value === undefined) return "NULL";
  return `'${String(value).replace(/'/g, "''")}'`;
}
