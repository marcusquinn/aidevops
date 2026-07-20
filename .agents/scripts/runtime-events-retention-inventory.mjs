// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, lstatSync, readdirSync } from "node:fs";
import { join } from "node:path";

function fileSize(filePath) {
  try {
    const entry = lstatSync(filePath);
    return entry.isFile() && !entry.isSymbolicLink() ? entry.size : null;
  } catch {
    return null;
  }
}

function activeStoreBytes(dbPath) {
  return [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]
    .map(fileSize)
    .filter((value) => value !== null)
    .reduce((total, value) => total + value, 0);
}

function archiveDirectoryBytes(archiveDir) {
  if (!existsSync(archiveDir)) return { error: null, files: new Map(), total: 0 };
  const files = new Map();
  let total = 0;
  try {
    if (lstatSync(archiveDir).isSymbolicLink()) {
      return { error: "archive-root-is-symlink", files, total };
    }
    for (const entry of readdirSync(archiveDir, { withFileTypes: true })) {
      if (!entry.isFile()) continue;
      const bytes = fileSize(join(archiveDir, entry.name));
      if (bytes === null) continue;
      files.set(entry.name, bytes);
      total += bytes;
    }
  } catch {
    return { error: "archive-inventory-unavailable", files, total };
  }
  return { error: null, files, total };
}

function verifiedArchiveInventory(manifests, archiveStorage, archiveDir, verifyArchive) {
  let error = null;
  let verifiedArchiveBytes = 0;
  for (const manifest of manifests) {
    const archiveBytes = archiveStorage.files.get(manifest.archive_file);
    const sidecarBytes = archiveStorage.files.get(`${manifest.archive_file}.manifest.json`);
    const verification = verifyArchive(join(archiveDir, manifest.archive_file));
    const matchesManifest = archiveBytes === Number(manifest.archive_bytes) &&
      sidecarBytes !== undefined && verification.ok &&
      verification.manifest?.archive_sha256 === manifest.archive_sha256;
    if (matchesManifest) verifiedArchiveBytes += archiveBytes + sidecarBytes;
    else error = "archive-verification-failed";
  }
  return { error, verifiedArchiveBytes };
}

function runtimeDbInventory(dbPath, cutoffAt, archiveDir, archiveStorage, dependencies) {
  const { sqlEscape, sqliteRows, verifyArchive } = dependencies;
  const empty = { candidateBytes: 0, error: null, protectedActiveBytes: 0, verifiedArchiveBytes: 0 };
  if (!existsSync(dbPath)) return empty;
  try {
    const tables = sqliteRows(dbPath, `
      SELECT name FROM sqlite_master WHERE type = 'table'
      AND name IN ('runtime_events', 'runtime_event_archives');
    `, { readonly: true });
    if (!tables.some((row) => row.name === "runtime_events")) throw new Error("schema-unavailable");
    const aggregates = sqliteRows(dbPath, `
      SELECT
        COALESCE(SUM(CASE WHEN occurred_at < ${sqlEscape(cutoffAt)} AND state_version IS NULL
          THEN payload_bytes ELSE 0 END), 0) AS candidate_bytes,
        COALESCE(SUM(CASE WHEN state_version IS NOT NULL THEN payload_bytes ELSE 0 END), 0)
          AS protected_active_bytes
      FROM runtime_events;
    `, { readonly: true })[0] || {};
    const hasArchiveTable = tables.some((row) => row.name === "runtime_event_archives");
    const manifests = hasArchiveTable
      ? sqliteRows(
        dbPath,
        "SELECT archive_file, archive_bytes, archive_sha256 FROM runtime_event_archives;",
        { readonly: true },
      )
      : [];
    const archiveInventory = verifiedArchiveInventory(
      manifests,
      archiveStorage,
      archiveDir,
      verifyArchive,
    );
    return {
      candidateBytes: Number(aggregates.candidate_bytes || 0),
      error: archiveInventory.error,
      protectedActiveBytes: Number(aggregates.protected_active_bytes || 0),
      verifiedArchiveBytes: archiveInventory.verifiedArchiveBytes,
    };
  } catch {
    return { ...empty, error: "inventory-unavailable" };
  }
}

/** Build a conservative physical/logical inventory without exposing payloads or private paths. */
export function buildRuntimeEventRetentionInventory(options, dependencies) {
  const {
    activeDaysDefault,
    canonicalizeDbPath,
    normalizedArchiveDir,
    normalizedCutoff,
    resolveDbPath,
    sqlEscape,
    sqliteRows,
    verifyArchive,
  } = dependencies;
  const dbPath = canonicalizeDbPath(options.dbPath || resolveDbPath());
  const archiveDir = normalizedArchiveDir(options.archiveDir, dbPath);
  const cutoffAt = normalizedCutoff(options.cutoff, options);
  const activeBytes = existsSync(dbPath) ? activeStoreBytes(dbPath) : 0;
  const archiveStorage = archiveDirectoryBytes(archiveDir);
  const dbInventory = runtimeDbInventory(dbPath, cutoffAt, archiveDir, archiveStorage, {
    sqlEscape,
    sqliteRows,
    verifyArchive,
  });
  const error = archiveStorage.error || dbInventory.error;
  const totalBytes = activeBytes + archiveStorage.total;
  const protectedBytes = Math.min(
    totalBytes,
    dbInventory.verifiedArchiveBytes + dbInventory.protectedActiveBytes,
  );
  return Object.freeze({
    active_bytes: activeBytes,
    archive_bytes: archiveStorage.total,
    candidate_bytes: dbInventory.candidateBytes,
    error,
    next_action: "observability-helper.sh retention --dry-run",
    policy: `${options.activeDays || activeDaysDefault}-day active window; verified archives; state recovery evidence pinned active`,
    protected_bytes: protectedBytes,
    reclaimable_bytes: 0,
    sizing_confidence: error ? "unavailable" : "estimated",
    total_bytes: totalBytes,
    unknown_bytes: Math.max(0, totalBytes - protectedBytes),
  });
}
