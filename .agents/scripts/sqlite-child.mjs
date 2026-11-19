// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * sqlite3 child-process primitives for sqlite-transport.mjs (GH#35702):
 * spawning the long-lived child and the exit-time flush.
 */

import { execFileSync, spawn } from "node:child_process";

const SQLITE_TIMEOUT_MS_RAW = Number.parseInt(process.env.AIDEVOPS_SQLITE_TIMEOUT_MS || "15000", 10);
export const SQLITE_TIMEOUT_MS = Number.isFinite(SQLITE_TIMEOUT_MS_RAW) && SQLITE_TIMEOUT_MS_RAW > 0
  ? SQLITE_TIMEOUT_MS_RAW
  : 15000;

const EXIT_FLUSH_TIMEOUT_MS = 2500;

/**
 * Exit-time flush. The in-flight query was already written to the child's
 * stdin, so we end stdin WITHOUT SIGTERM: sqlite3 finishes it on EOF as an
 * independent process (no re-run, so no duplicate row). Writes never sent
 * (still queued) run once via a bounded synchronous sqlite3 call. Fails open.
 */
export function flushTransportOnExit(transport) {
  const pending = transport.queue.splice(0).map((query) => query.sql);
  const proc = transport.proc;
  transport.proc = null;
  if (proc) {
    try { proc.stdin.end(); } catch { /* already dead */ }
  }
  if (pending.length > 0) {
    try {
      execFileSync("sqlite3", ["-cmd", `.timeout ${EXIT_FLUSH_TIMEOUT_MS}`, transport.dbPath], {
        input: `${pending.join("\n")}\n`,
        timeout: EXIT_FLUSH_TIMEOUT_MS + 500,
        stdio: ["pipe", "ignore", "pipe"],
      });
    } catch (error) {
      console.error(`[aidevops] SQLite exit flush failed (${pending.length} writes dropped): ${String(error.message).split("\n")[0]}`);
    }
  }
  transport.processing = false;
  transport.currentCallback = null;
  transport.stdoutBuffer = "";
  transport.closeWhenIdle = false;
}

export function startChild(dbPath) {
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
