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
  const probe = { timeoutMs: Math.min(30000, Math.max(1, deadlineLeft(clock, deadline))) };
  if (!tableExists(dbPath, "tool_calls", probe)) return { deleted, complete: true };
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
export function enableIncrementalVacuum(dbPath, { timeoutMs = 3600000 } = {}) {
  if (numberPragma(dbPath, "auto_vacuum") === AUTO_VACUUM_INCREMENTAL) return false;
  sqlite(dbPath, "PRAGMA auto_vacuum = INCREMENTAL; VACUUM;", { timeoutMs });
  return true;
}

/** Return freelist pages to the filesystem in bounded chunks. */
export function reclaimFreePages(dbPath, { clock, deadline }) {
  const probe = { timeoutMs: Math.min(30000, Math.max(1, deadlineLeft(clock, deadline))) };
  const autoVacuum = numberPragma(dbPath, "auto_vacuum", probe);
  const pageSize = numberPragma(dbPath, "page_size", probe);
  const before = numberPragma(dbPath, "freelist_count", probe);
  if (autoVacuum !== AUTO_VACUUM_INCREMENTAL) {
    return { auto_vacuum: autoVacuum, reclaimed_bytes: 0, vacuum_required: before > 0 || autoVacuum === 0 };
  }
  let remaining = before;
  while (remaining > 0) {
    const left = deadlineLeft(clock, deadline);
    if (left <= 0) break;
    sqlite(dbPath, `PRAGMA incremental_vacuum(${INCREMENTAL_VACUUM_CHUNK_PAGES});`, { timeoutMs: Math.min(30000, left) });
    remaining = numberPragma(dbPath, "freelist_count", { timeoutMs: 30000 });
  }
  sqlite(dbPath, "PRAGMA wal_checkpoint(TRUNCATE);", { timeoutMs: 30000 });
  return { auto_vacuum: autoVacuum, reclaimed_bytes: (before - remaining) * pageSize, vacuum_required: false };
}
