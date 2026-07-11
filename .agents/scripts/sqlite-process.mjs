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

let sqliteProc = null;
let queryQueue = [];
let processing = false;
let currentCallback = null;
let stdoutBuffer = "";
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

/** Set the database path before operations. Changing it shuts down the old process. */
export function setDbPath(value) {
  const canonical = canonicalizeSqliteDbPath(value);
  if (dbPath && dbPath !== canonical) shutdownSqlite();
  dbPath = canonical;
  return dbPath;
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

function spawnSqlite() {
  if (sqliteProc) return;
  const configuredPath = getDbPath();

  try {
    sqliteProc = spawn("sqlite3", ["-cmd", `.timeout ${SQLITE_TIMEOUT_MS}`, configuredPath], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    sqliteProc.stdin.write(
      `PRAGMA busy_timeout=${SQLITE_TIMEOUT_MS};\nPRAGMA journal_mode=WAL;\nPRAGMA synchronous=NORMAL;\n`,
    );
  } catch (error) {
    console.error(`[aidevops] Failed to spawn sqlite3: ${error.message}`);
    return;
  }

  sqliteProc.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString();
    const index = stdoutBuffer.indexOf(SQLITE_SENTINEL);
    if (index === -1) return;

    const result = stdoutBuffer.substring(0, index).trim();
    const endOfLine = stdoutBuffer.indexOf("\n", index);
    stdoutBuffer = endOfLine !== -1 ? stdoutBuffer.substring(endOfLine + 1) : "";
    const callback = currentCallback;
    currentCallback = null;
    processing = false;
    if (callback) callback(null, result);
    drainQueue();
  });

  sqliteProc.stderr.on("data", (chunk) => {
    const message = chunk.toString().trim();
    if (message && !isSqliteBusyError(message)) console.error(`[aidevops] SQLite: ${message}`);
  });

  sqliteProc.on("close", (code) => {
    sqliteProc = null;
    stdoutBuffer = "";
    if (currentCallback) {
      const callback = currentCallback;
      currentCallback = null;
      processing = false;
      callback(new Error(`sqlite3 exited with code ${code}`));
    }
    if (queryQueue.length > 0) {
      spawnSqlite();
      drainQueue();
    }
  });

  sqliteProc.on("error", (error) => {
    console.error(`[aidevops] SQLite process error: ${error.message}`);
    sqliteProc = null;
    if (currentCallback) {
      const callback = currentCallback;
      currentCallback = null;
      processing = false;
      callback(error);
    }
  });
}

function drainQueue() {
  if (processing || queryQueue.length === 0) return;
  if (!sqliteProc) spawnSqlite();
  if (!sqliteProc) {
    const pending = queryQueue.splice(0);
    const error = new Error("sqlite3 process unavailable");
    for (const query of pending) query.callback(error, "");
    return;
  }

  processing = true;
  const { sql, callback } = queryQueue.shift();
  currentCallback = callback;
  try {
    sqliteProc.stdin.write(`${sql}\nSELECT '${SQLITE_SENTINEL}';\n`);
  } catch (error) {
    processing = false;
    currentCallback = null;
    callback(error, "");
    drainQueue();
  }
}

export function sqliteExec(sql) {
  const queueMax = Number.isFinite(SQLITE_QUEUE_MAX) && SQLITE_QUEUE_MAX > 0 ? SQLITE_QUEUE_MAX : 1000;
  if (queryQueue.length >= queueMax) {
    if (process.env.AIDEVOPS_SQLITE_QUEUE_WARN !== "0") {
      console.error(`[aidevops] SQLite async queue full (${queueMax}); dropping observability write`);
    }
    return false;
  }
  queryQueue.push({
    sql,
    callback: (error) => {
      if (error && !isSqliteBusyError(error.message)) {
        console.error(`[aidevops] SQLite async exec failed: ${error.message}`);
      }
    },
  });
  drainQueue();
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

export function shutdownSqlite() {
  if (sqliteProc) {
    try {
      sqliteProc.stdin.end();
      sqliteProc.kill("SIGTERM");
    } catch {
      // Process may already be dead.
    }
  }
  sqliteProc = null;
  queryQueue = [];
  processing = false;
  currentCallback = null;
  stdoutBuffer = "";
}

export function sqlEscape(value) {
  if (value === null || value === undefined) return "NULL";
  return `'${String(value).replace(/'/g, "''")}'`;
}
