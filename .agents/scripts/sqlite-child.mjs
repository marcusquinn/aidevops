// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * sqlite3 child-process primitives for sqlite-transport.mjs (GH#35702):
 * spawning the long-lived child and the exit-time flush.
 */

import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SQLITE_TIMEOUT_MS_RAW = Number.parseInt(process.env.AIDEVOPS_SQLITE_TIMEOUT_MS || "15000", 10);
export const SQLITE_TIMEOUT_MS = Number.isFinite(SQLITE_TIMEOUT_MS_RAW) && SQLITE_TIMEOUT_MS_RAW > 0
  ? SQLITE_TIMEOUT_MS_RAW
  : 15000;

const EXIT_FLUSH_TIMEOUT_MS = 2500;

// The exit hook cannot service stdout or await stream callbacks. A tiny shell
// command behind the delivered SQL provides a portable completion fence without
// relying on private pipe descriptors or replaying a query that may have run.
function waitForInflight(proc) {
  const dir = mkdtempSync(join(tmpdir(), "aidevops-sqlite-fence-"));
  const marker = join(dir, "done");
  try {
    proc.stdin.write(`.once ${JSON.stringify(marker)}\nSELECT '__AIDEVOPS_EXIT_DONE__';\n`);
    if (proc.stdin.writableLength !== 0 || proc.stdin.destroyed || proc.stdin.errored) {
      throw new Error("sqlite3 completion fence was not handed off");
    }
    proc.stdin.end();
    const deadline = Date.now() + EXIT_FLUSH_TIMEOUT_MS;
    const sleeper = new Int32Array(new SharedArrayBuffer(4));
    while (Date.now() < deadline) {
      try {
        if (readFileSync(marker, "utf8").includes("__AIDEVOPS_EXIT_DONE__")) return;
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
      Atomics.wait(sleeper, 0, 0, 5);
    }
    throw new Error("sqlite3 completion fence timed out");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/**
 * Exit-time flush. The in-flight query was already written to the child's
 * stdin, so we end stdin WITHOUT SIGTERM: sqlite3 finishes it on EOF as an
 * independent process (no re-run, so no duplicate row). Writes never sent
 * (still queued) run once via a bounded synchronous sqlite3 call, after a
 * completion fence if the child still owns a query. Fails open on timeout.
 */
export function flushTransportOnExit(transport) {
  const pending = transport.queue.splice(0).map((query) => query.sql);
  const proc = transport.proc;
  transport.proc = null;
  if (proc) {
    if (transport.processing && transport.inflightSql &&
        (!transport.inflightFlushed || proc.stdin.destroyed || proc.stdin.errored)) {
      // The write has not fully reached the child (e.g. larger than pipe
      // capacity): exit would drop its unflushed suffix, including the
      // terminator, so the statement cannot have executed. Kill the child and
      // replay it once synchronously.
      try { proc.kill("SIGKILL"); } catch { /* already dead */ }
      pending.unshift(transport.inflightSql);
    } else {
      if (transport.processing && transport.inflightSql && pending.length > 0) {
        try {
          waitForInflight(proc);
        } catch (error) {
          // Do not let another writer overtake an unconfirmed query, and never
          // replay SQL already delivered to the child. Report loss explicitly.
          console.error(`[aidevops] SQLite exit ordering failed (${pending.length} writes dropped): ${error.message}`);
          pending.length = 0;
        }
      }
      try { proc.stdin.end(); } catch { /* already dead */ }
    }
  }
  transport.inflightSql = null;
  transport.inflightFlushed = true;
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
