// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Runtime-neutral sqlite3 process transport shared by scripts and plugins. */

import { execFileSync } from "node:child_process";
import { existsSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import {
  SQLITE_TIMEOUT_MS,
  acquireTransport,
  drainQueue,
  existingTransport,
  isSqliteBusyError,
  stopTransport,
  transportFor,
  transportStats,
} from "./sqlite-transport.mjs";

export { isSqliteBusyError };

const SQLITE_QUEUE_MAX = Number.parseInt(process.env.AIDEVOPS_SQLITE_QUEUE_MAX || "1000", 10);

let dbPath = "";

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
    const previous = existingTransport(dbPath);
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
  return acquireTransport(getDbPath());
}

/** Diagnostics: live transport children and owners in this process. */
export function sqliteTransportStats() {
  return transportStats();
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

/** Force-stop the configured database's transport (tests, CLI teardown). */
export function shutdownSqlite() {
  if (!dbPath) return;
  const transport = existingTransport(dbPath);
  if (transport) stopTransport(transport);
}

export function sqlEscape(value) {
  if (value === null || value === undefined) return "NULL";
  return `'${String(value).replace(/'/g, "''")}'`;
}
