// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Validates the OpenCode data home and database named by a Tabby recovery
// marker. V1 isolates each project under opencode-interactive/*; V2 shares one
// data home whose sessions live in the session_v2 table.

import { lstatSync, realpathSync } from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const SESSION_TABLES = { v1: "session", v2: "session_v2" };
const CONTROL_CHAR_RE = /[\u0000-\u001F\u007F]/;

export function pathIsInside(parent, candidate) {
  const child = relative(parent, candidate);
  return child === "" || (!child.startsWith("..") && !isAbsolute(child));
}

function assertOwnedDirectory(path, uid, message) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid) throw new Error(message);
}

// sessionID must already match the marker session ID pattern; the table name
// is a fixed constant.
function querySessionDirectory(databasePath, sessionID, runtime) {
  const sql = `SELECT directory FROM ${SESSION_TABLES[runtime]} WHERE id='${sessionID}' AND parent_id IS NULL LIMIT 2;`;
  const result = spawnSync("sqlite3", ["-readonly", databasePath, sql], {
    encoding: "utf8",
    timeout: 5000,
  });
  if (result.error || result.status !== 0) throw new Error("Could not validate OpenCode recovery database");
  const rows = result.stdout.trimEnd().split("\n").filter(Boolean);
  if (rows.length !== 1) throw new Error("OpenCode recovery session was not found");
  return rows[0];
}

function canonicalV1DataDir(dataDir, workDir, uid) {
  assertOwnedDirectory(dataDir, uid, "Unsafe OpenCode recovery data directory");
  const canonicalDataDir = realpathSync(dataDir);
  const isolatedRootPath = join(resolve(workDir), "opencode-interactive");
  assertOwnedDirectory(isolatedRootPath, uid, "Unsafe OpenCode isolated storage root");
  const isolatedRoot = realpathSync(isolatedRootPath);
  if (!pathIsInside(isolatedRoot, canonicalDataDir) || canonicalDataDir === isolatedRoot) {
    throw new Error("Recovery marker data directory is outside isolated storage");
  }
  return canonicalDataDir;
}

// V2 has one shared data home, so the marker must name exactly the data home
// the caller's V2 shim is using; anything else fails closed.
function canonicalV2DataDir(dataDir, expectedDataDir, uid) {
  if (typeof expectedDataDir !== "string" || !isAbsolute(expectedDataDir) || CONTROL_CHAR_RE.test(expectedDataDir)) {
    throw new Error("OpenCode V2 recovery requires an absolute V2 data directory");
  }
  assertOwnedDirectory(dataDir, uid, "Unsafe OpenCode recovery data directory");
  assertOwnedDirectory(expectedDataDir, uid, "Unsafe OpenCode recovery data directory");
  const canonicalDataDir = realpathSync(dataDir);
  if (canonicalDataDir !== realpathSync(expectedDataDir)) {
    throw new Error("Recovery marker data directory is not the OpenCode V2 data directory");
  }
  return canonicalDataDir;
}

// Returns the canonical data home once the marker's session is proven to be a
// root session in that data home's database for canonicalDirectory.
export function validateRecoveryData({ runtime, dataDir, expectedDataDir, workDir, uid, sessionID, canonicalDirectory }) {
  const canonicalDataDir = runtime === "v2"
    ? canonicalV2DataDir(dataDir, expectedDataDir, uid)
    : canonicalV1DataDir(dataDir, workDir, uid);
  const databasePath = join(canonicalDataDir, "opencode", "opencode.db");
  const databaseStat = lstatSync(databasePath);
  if (!databaseStat.isFile() || databaseStat.isSymbolicLink() || databaseStat.uid !== uid) {
    throw new Error("Unsafe OpenCode recovery database");
  }
  if (realpathSync(querySessionDirectory(databasePath, sessionID, runtime)) !== canonicalDirectory) {
    throw new Error("Recovery marker directory does not match the OpenCode session");
  }
  return canonicalDataDir;
}
