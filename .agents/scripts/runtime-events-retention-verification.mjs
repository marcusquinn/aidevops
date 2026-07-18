// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { lstatSync, readFileSync } from "node:fs";
import { basename } from "node:path";

/** Verify a partition and sidecar without trusting filenames or row claims. */
export function verifyArchiveArtifacts({ archivePath, digest, manifestPath, schemaVersion }) {
  const errors = [];
  let manifest = null;
  let contents = "";
  try {
    if (lstatSync(archivePath).isSymbolicLink() || lstatSync(manifestPath).isSymbolicLink()) {
      throw new Error("archive artifacts must not be symbolic links");
    }
    contents = readFileSync(archivePath, "utf8");
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    const lines = contents.trimEnd().split("\n").map((line) => JSON.parse(line));
    const header = lines[0];
    const eventCount = lines.slice(1).filter((record) => record.record_type === "event").length;
    const compactedCount = lines.slice(1)
      .filter((record) => record.record_type === "summary")
      .reduce((total, record) => total + Number(record.count || 0), 0);
    if (header.record_type !== "manifest" || header.schema_version !== schemaVersion) {
      errors.push("invalid archive header");
    }
    if (manifest.archive_sha256 !== digest(contents)) errors.push("archive digest mismatch");
    if (manifest.archive_file !== basename(archivePath)) errors.push("archive filename mismatch");
    if (manifest.archive_bytes !== Buffer.byteLength(contents, "utf8")) {
      errors.push("archive byte count mismatch");
    }
    if (manifest.archive_record_count !== lines.length - 1) errors.push("archive record count mismatch");
    if (manifest.protected_row_count !== eventCount) errors.push("protected event count mismatch");
    if (manifest.compacted_row_count !== compactedCount) errors.push("compacted event count mismatch");
    if (manifest.source_row_count !== eventCount + compactedCount) errors.push("source event count mismatch");
    if (manifest.partition_id !== header.partition_id || manifest.source_sha256 !== header.source_sha256) {
      errors.push("archive manifest/header mismatch");
    }
  } catch (error) {
    errors.push(error instanceof Error ? error.message : "archive verification failed");
  }
  return Object.freeze({ errors, manifest, ok: errors.length === 0 });
}
