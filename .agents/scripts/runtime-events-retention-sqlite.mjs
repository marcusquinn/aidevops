// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Bounded SQLite execution and sanitized stage diagnostics for retention. */

import { execFileSync } from "node:child_process";

const SQLITE_OUTPUT_MAX_BYTES = 256 * 1024 * 1024;

export function sqlite(dbPath, sql, { json = false, readonly = false, timeoutMs = 30000 } = {}) {
  // Leave time for SQLite to report contention and roll back before the process
  // watchdog fires. Every connection shares the remaining maintenance budget.
  const busyMs = Math.max(1, Math.min(15000, timeoutMs - Math.min(1000, timeoutMs / 2)));
  const args = ["-cmd", `.timeout ${Math.floor(busyMs)}`];
  if (json) args.push("-json");
  if (readonly) args.push("-readonly");
  args.push(dbPath);
  return execFileSync("sqlite3", args, {
    encoding: "utf8",
    input: sql,
    // A full archive batch returns up to max-rows events with 16 KiB payloads
    // as escaped JSON, far beyond Node's 1 MiB default (ENOBUFS).
    maxBuffer: SQLITE_OUTPUT_MAX_BYTES,
    stdio: ["pipe", "pipe", "pipe"],
    timeout: timeoutMs,
  }).trim();
}

export function retentionStages(options) {
  const budget = options.sqliteBudgetMs;
  if (budget !== undefined && (!Number.isSafeInteger(budget) || budget < 1 || budget > 3600000)) {
    throw new TypeError("SQLite budget must be an integer from 1 to 3600000 milliseconds");
  }
  const deadline = budget === undefined ? Infinity : performance.now() + budget;
  let partitionId;
  return {
    setPartition: (value) => { partitionId = value; },
    run(stage, action) {
      const started = performance.now();
      try {
        const remaining = Math.ceil(deadline - started);
        if (remaining <= 0) throw Object.assign(new Error(), { code: "ETIMEDOUT" });
        return action(Math.min(30000, remaining));
      } catch (error) {
        if (error?.retentionStage) throw error;
        const kind = error?.code === "ETIMEDOUT" ? "timeout"
          : /database is (locked|busy)|SQLITE_BUSY|SQLITE_LOCKED/i.test(String(error?.stderr || ""))
            ? "busy" : "failed";
        // Never interpolate child stderr, SQL, payloads or filesystem paths.
        // A killed writer may already have committed: retries must reselect and
        // verify artifacts rather than deleting them or assuming zero changes.
        const label = stage === "persist_archive" ? "archive partition verification failed" : "retention stage failed";
        throw Object.assign(new Error(`${label}: stage=${stage} kind=${kind} elapsed_ms=${Math.round(performance.now() - started)}` +
          (partitionId ? ` partition_id=${partitionId}` : "") +
          " commit_state=unknown recovery=retry_verified_retention"), { retentionStage: stage });
      }
    },
  };
}

export function sqliteRows(dbPath, sql, options = {}) {
  const output = sqlite(dbPath, sql, { ...options, json: true });
  if (!output) return [];
  const parsed = JSON.parse(output);
  return Array.isArray(parsed) ? parsed : [];
}
