/**
 * Persistent SQLite Process Manager for LLM Observability.
 * Extracted from observability.mjs to reduce file-level complexity.
 *
 * Two execution modes:
 *   sqliteExecSync(sql, timeout) — forks a new process per call. Init-time only.
 *   sqliteExec(sql) — writes to a persistent sqlite3 child. Fire-and-forget.
 */

import { execSync, spawn } from "child_process";

const SQLITE_SENTINEL = "__AIDEVOPS_QUERY_DONE__";

let _sqliteProc = null;
let _queryQueue = [];
let _processing = false;
let _currentCallback = null;
let _stdoutBuf = "";

let _dbPath = "";

/** Set the database path (must be called before any operations). */
export function setDbPath(path) {
  _dbPath = path;
}

function _spawnSqlite() {
  if (_sqliteProc) return;

  try {
    _sqliteProc = spawn("sqlite3", ["-cmd", ".timeout 5000", _dbPath], {
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (err) {
    console.error(`[aidevops] Failed to spawn sqlite3: ${err.message}`);
    return;
  }

  _sqliteProc.stdout.on("data", (chunk) => {
    _stdoutBuf += chunk.toString();
    const idx = _stdoutBuf.indexOf(SQLITE_SENTINEL);
    if (idx !== -1) {
      const result = _stdoutBuf.substring(0, idx).trim();
      const endOfLine = _stdoutBuf.indexOf("\n", idx);
      _stdoutBuf = endOfLine !== -1 ? _stdoutBuf.substring(endOfLine + 1) : "";

      const cb = _currentCallback;
      _currentCallback = null;
      _processing = false;
      if (cb) cb(null, result);
      _drainQueue();
    }
  });

  _sqliteProc.stderr.on("data", (chunk) => {
    const msg = chunk.toString().trim();
    if (msg) console.error(`[aidevops] SQLite: ${msg}`);
  });

  _sqliteProc.on("close", (code) => {
    _sqliteProc = null;
    _stdoutBuf = "";
    if (_currentCallback) {
      const cb = _currentCallback;
      _currentCallback = null;
      _processing = false;
      cb(new Error(`sqlite3 exited with code ${code}`));
    }
    if (_queryQueue.length > 0) {
      _spawnSqlite();
      _drainQueue();
    }
  });

  _sqliteProc.on("error", (err) => {
    console.error(`[aidevops] SQLite process error: ${err.message}`);
    _sqliteProc = null;
    if (_currentCallback) {
      const cb = _currentCallback;
      _currentCallback = null;
      _processing = false;
      cb(err);
    }
  });
}

function _drainQueue() {
  if (_processing || _queryQueue.length === 0) return;
  if (!_sqliteProc) _spawnSqlite();
  if (!_sqliteProc) {
    const pending = _queryQueue.splice(0);
    const err = new Error("sqlite3 process unavailable");
    for (const q of pending) q.callback(err, "");
    return;
  }

  _processing = true;
  const { sql, callback } = _queryQueue.shift();
  _currentCallback = callback;

  try {
    _sqliteProc.stdin.write(`${sql}\nSELECT '${SQLITE_SENTINEL}';\n`);
  } catch (err) {
    _processing = false;
    _currentCallback = null;
    callback(err, "");
    _drainQueue();
  }
}

export function sqliteExec(sql) {
  _queryQueue.push({
    sql,
    callback: (err) => {
      if (err) console.error(`[aidevops] SQLite async exec failed: ${err.message}`);
    },
  });
  _drainQueue();
}

export function sqliteExecSync(sql, timeout = 5000) {
  try {
    return execSync(`sqlite3 -cmd ".timeout 5000" "${_dbPath}"`, {
      input: sql,
      encoding: "utf-8",
      timeout,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    console.error(`[aidevops] SQLite sync exec failed: ${e.stderr || e.message}`);
    return null;
  }
}

export function shutdownSqlite() {
  if (!_sqliteProc) return;
  try {
    _sqliteProc.stdin.end();
    _sqliteProc.kill("SIGTERM");
  } catch {
    // Process may already be dead
  }
  _sqliteProc = null;
  _queryQueue = [];
  _processing = false;
  _currentCallback = null;
  _stdoutBuf = "";
}

export function sqlEscape(value) {
  if (value === null || value === undefined) return "NULL";
  return `'${String(value).replace(/'/g, "''")}'`;
}
