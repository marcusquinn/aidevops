// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Physical-space helpers for runtime-event retention (GH#40498): dbstat-based
 * sizing, tool_calls pruning and page reclamation after verified deletes.
 */

import { sqlite } from "./runtime-events-retention-sqlite.mjs";

const AUTO_VACUUM_INCREMENTAL = 2;
const TOOL_CALLS_BATCH_ROWS = 50000;
const INCREMENTAL_VACUUM_CHUNK_PAGES = 20000;

function numberPragma(dbPath, pragma, options = {}) {
  return Number(sqlite(dbPath, `PRAGMA ${pragma};`, options) || 0);
}

/** Page-level facts; objectBytes is null when dbstat is unavailable. */
export function readSpaceStats(dbPath, sqliteRows, { timeoutMs } = {}) {
  const options = { readonly: true, timeoutMs };
  const pageSize = numberPragma(dbPath, "page_size", options);
  const pageCount = numberPragma(dbPath, "page_count", options);
  const freelistCount = numberPragma(dbPath, "freelist_count", options);
  const autoVacuum = numberPragma(dbPath, "auto_vacuum", options);
  let objectBytes = null;
  try {
    const rows = sqliteRows(dbPath, `
      SELECT m.tbl_name AS tbl, SUM(d.pgsize) AS bytes
      FROM dbstat d JOIN sqlite_master m ON m.name = d.name
      GROUP BY m.tbl_name;
    `, options);
    objectBytes = new Map(rows.map((row) => [row.tbl, Number(row.bytes || 0)]));
  } catch {
    objectBytes = null;
  }
  return {
    autoVacuum,
    freelistBytes: freelistCount * pageSize,
    objectBytes,
    pageCount,
    pageSize,
  };
}

/** Table-plus-index bytes attributable to the given share of a table's rows. */
export function physicalShareBytes(stats, table, shareRows, totalRows) {
  const tableBytes = stats?.objectBytes?.get(table);
  if (!tableBytes || !totalRows || !shareRows) return null;
  return Math.round(tableBytes * Math.min(1, shareRows / totalRows));
}

function tableExists(dbPath, table, options) {
  return Number(sqlite(
    dbPath,
    `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '${table}';`,
    options,
  ) || 0) > 0;
}

/** Rows in tool_calls older than the cutoff (0 when the table is absent). */
export function countToolCallCandidates(dbPath, cutoffAt, sqlEscape, options = {}) {
  const readonly = { readonly: true, ...options };
  if (!tableExists(dbPath, "tool_calls", readonly)) return { candidate: 0, total: 0 };
  const row = sqlite(
    dbPath,
    `SELECT SUM(timestamp < ${sqlEscape(cutoffAt)}) || '|' || COUNT(*) FROM tool_calls;`,
    readonly,
  );
  const [candidate, total] = String(row || "0|0").split("|").map((value) => Number(value) || 0);
  return { candidate, total };
}

function deadlineLeft(clock, deadline) {
  return Math.max(0, Math.floor(deadline - clock()));
}

/**
 * Delete tool_calls older than the cutoff in bounded batches. These rows are
 * derived diagnostics (no archive); the retention window matches runtime_events.
 */
export function pruneToolCalls(dbPath, cutoffAt, { clock, deadline, sqlEscape }) {
  let deleted = 0;
  const probeMs = Math.min(30000, deadlineLeft(clock, deadline));
  if (probeMs <= 0) return { deleted, complete: false };
  if (!tableExists(dbPath, "tool_calls", { timeoutMs: probeMs })) return { deleted, complete: true };
  for (;;) {
    const left = deadlineLeft(clock, deadline);
    if (left <= 0) return { deleted, complete: false };
    const batch = Number(sqlite(dbPath, `
      DELETE FROM tool_calls WHERE id IN (
        SELECT id FROM tool_calls WHERE timestamp < ${sqlEscape(cutoffAt)} LIMIT ${TOOL_CALLS_BATCH_ROWS}
      );
      SELECT changes();
    `, { timeoutMs: Math.min(30000, left) }) || 0);
    deleted += batch;
    if (batch < TOOL_CALLS_BATCH_ROWS) return { deleted, complete: true };
  }
}

/** One-off conversion; needs free disk about the file size and an idle writer. */
export function enableIncrementalVacuum(dbPath, { clock, deadline }) {
  const left = deadlineLeft(clock, deadline);
  if (left <= 0) return false;
  if (numberPragma(dbPath, "auto_vacuum", { timeoutMs: Math.min(30000, left) }) === AUTO_VACUUM_INCREMENTAL) return false;
  const vacuumMs = deadlineLeft(clock, deadline);
  if (vacuumMs <= 0) return false;
  // A timeout kills sqlite3 and rolls the VACUUM back; rerun with a longer budget.
  sqlite(dbPath, "PRAGMA auto_vacuum = INCREMENTAL; VACUUM;", { timeoutMs: vacuumMs });
  return true;
}

/** After verified deletes: prune tool_calls, then return free pages (GH#40498). */
export function reclaimAfterArchive(dbPath, cutoffAt, { clock, deadline, enableIncrementalVacuum: convert }, sqlEscape) {
  if (deadlineLeft(clock, deadline) <= 0) return { space_reclaim_skipped: "max_duration" };
  const converted = convert ? enableIncrementalVacuum(dbPath, { clock, deadline }) : false;
  const toolCalls = pruneToolCalls(dbPath, cutoffAt, { clock, deadline, sqlEscape });
  const pages = reclaimFreePages(dbPath, { clock, deadline });
  return {
    auto_vacuum: pages.auto_vacuum,
    incremental_vacuum_enabled: converted,
    reclaimed_bytes: pages.reclaimed_bytes,
    tool_calls_deleted: toolCalls.deleted,
    tool_calls_prune_complete: toolCalls.complete,
    vacuum_required: pages.vacuum_required,
  };
}

/** Run one pragma read within the remaining budget; null when none remains. */
function budgetedPragma(dbPath, pragma, { clock, deadline }) {
  const left = Math.min(30000, deadlineLeft(clock, deadline));
  return left > 0 ? numberPragma(dbPath, pragma, { timeoutMs: left }) : null;
}

/** Return freelist pages to the filesystem in bounded chunks. */
export function reclaimFreePages(dbPath, budget) {
  const { clock, deadline } = budget;
  const autoVacuum = budgetedPragma(dbPath, "auto_vacuum", budget);
  const pageSize = budgetedPragma(dbPath, "page_size", budget);
  const before = budgetedPragma(dbPath, "freelist_count", budget);
  if (autoVacuum === null || pageSize === null || before === null) {
    return { auto_vacuum: autoVacuum, reclaimed_bytes: 0, vacuum_required: false };
  }
  if (autoVacuum !== AUTO_VACUUM_INCREMENTAL) {
    return { auto_vacuum: autoVacuum, reclaimed_bytes: 0, vacuum_required: before > 0 || autoVacuum === 0 };
  }
  let remaining = before;
  while (remaining > 0) {
    const left = deadlineLeft(clock, deadline);
    if (left <= 0) break;
    sqlite(dbPath, `PRAGMA incremental_vacuum(${INCREMENTAL_VACUUM_CHUNK_PAGES});`, { timeoutMs: Math.min(30000, left) });
    remaining = budgetedPragma(dbPath, "freelist_count", budget) ?? remaining;
  }
  const checkpointMs = Math.min(30000, deadlineLeft(clock, deadline));
  if (checkpointMs > 0) sqlite(dbPath, "PRAGMA wal_checkpoint(TRUNCATE);", { timeoutMs: checkpointMs });
  return { auto_vacuum: autoVacuum, reclaimed_bytes: (before - remaining) * pageSize, vacuum_required: false };
}
