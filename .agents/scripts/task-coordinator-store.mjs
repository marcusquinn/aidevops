// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Task coordinator storage layer: schema, migrations, bootstrap and SQLite access.

import { randomBytes, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { canonicalizeSqliteDbPath, sqlEscape } from "./sqlite-process.mjs";
import { acquireInitializationLock, releaseInitializationLock } from "./task-coordinator-lock.mjs";

const SCHEMA_VERSION = 8;
const CROCKFORD = "0123456789abcdefghjkmnpqrstvwxyz";

const SCHEMA = `
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS coordinator_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS origins (
  origin_id TEXT PRIMARY KEY, state TEXT NOT NULL, sequence INTEGER NOT NULL DEFAULT 0 CHECK(sequence >= 0),
  ownership_epoch INTEGER NOT NULL DEFAULT 1 CHECK(ownership_epoch > 0), fencing_token TEXT NOT NULL,
  created_at TEXT NOT NULL, CHECK(state IN ('active','read-only','redirected','retired','quarantined'))
);
CREATE TABLE IF NOT EXISTS origin_transitions (
  id INTEGER PRIMARY KEY, origin_id TEXT NOT NULL REFERENCES origins(origin_id),
  from_state TEXT, to_state TEXT NOT NULL, ownership_epoch INTEGER NOT NULL,
  fencing_token TEXT NOT NULL, evidence_json TEXT NOT NULL CHECK(json_valid(evidence_json)), occurred_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tasks (
  task_id TEXT PRIMARY KEY, origin_id TEXT NOT NULL REFERENCES origins(origin_id),
  sequence INTEGER NOT NULL CHECK(sequence > 0), parent_task_id TEXT REFERENCES tasks(task_id),
  created_operation_id TEXT NOT NULL, payload_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), created_at TEXT NOT NULL, UNIQUE(origin_id, sequence)
);
CREATE TABLE IF NOT EXISTS operations (
  operation_id TEXT PRIMARY KEY, kind TEXT NOT NULL, task_id TEXT,
  payload_hash TEXT NOT NULL, payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), status TEXT NOT NULL,
  result_json TEXT NOT NULL CHECK(json_valid(result_json)),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  CHECK(status IN ('published','retryable','indeterminate','terminal','conflict'))
);
CREATE TABLE IF NOT EXISTS publication_intents (
  intent_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES operations(operation_id),
  task_id TEXT NOT NULL REFERENCES tasks(task_id), payload_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), status TEXT NOT NULL DEFAULT 'retryable', created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS publication_queue (
  intent_id TEXT PRIMARY KEY REFERENCES publication_intents(intent_id), repository_id TEXT NOT NULL,
  repository_path TEXT NOT NULL, remote_name TEXT NOT NULL, branch_name TEXT NOT NULL,
  coalesce_key TEXT NOT NULL, sequence INTEGER NOT NULL UNIQUE, available_at INTEGER NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 5,
  lease_token INTEGER, CHECK(attempt_count >= 0), CHECK(max_attempts > 0)
);
CREATE TABLE IF NOT EXISTS publication_leases (
  repository_id TEXT PRIMARY KEY, fencing_token INTEGER NOT NULL CHECK(fencing_token > 0),
  owner_id TEXT NOT NULL, expires_at INTEGER NOT NULL, acquired_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS publication_attempts (
  id INTEGER PRIMARY KEY, intent_id TEXT NOT NULL REFERENCES publication_intents(intent_id),
  attempt_number INTEGER NOT NULL, status TEXT NOT NULL, evidence_json TEXT NOT NULL CHECK(json_valid(evidence_json)),
  occurred_at TEXT NOT NULL, UNIQUE(intent_id, attempt_number)
);
CREATE TABLE IF NOT EXISTS terminal_evidence (
  id INTEGER PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES operations(operation_id),
  result_state TEXT NOT NULL, evidence_json TEXT NOT NULL CHECK(json_valid(evidence_json)), occurred_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS migration_history (
  version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL, backup_path TEXT, integrity_result TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS restore_controls (
  id INTEGER PRIMARY KEY, origin_id TEXT NOT NULL, prior_epoch INTEGER NOT NULL,
  new_epoch INTEGER NOT NULL, fencing_token TEXT NOT NULL UNIQUE,
  registry_evidence_json TEXT NOT NULL CHECK(json_valid(registry_evidence_json)), backup_integrity TEXT NOT NULL,
  backup_high_water INTEGER NOT NULL, published_high_water INTEGER NOT NULL, restored_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS issue_mappings (
  task_id TEXT NOT NULL, forge TEXT NOT NULL, repository_id TEXT NOT NULL,
  repository_slug TEXT NOT NULL, role TEXT NOT NULL, issue_id TEXT NOT NULL,
  project_id TEXT, display_number INTEGER NOT NULL CHECK(display_number > 0),
  state_cursor TEXT, sync_metadata_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(sync_metadata_json)),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  PRIMARY KEY(task_id, forge, repository_id),
  UNIQUE(forge, repository_id, issue_id),
  UNIQUE(forge, repository_id, display_number),
  CHECK(forge IN ('github')), CHECK(role IN ('home','implementation','upstream'))
);
CREATE TABLE IF NOT EXISTS legacy_task_adoptions (
  task_id TEXT PRIMARY KEY REFERENCES tasks(task_id), repository_id TEXT NOT NULL,
  adopted_operation_id TEXT NOT NULL REFERENCES operations(operation_id), adopted_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS repository_task_aliases (
  local_task_id TEXT NOT NULL, forge TEXT NOT NULL, repository_id TEXT NOT NULL, task_id TEXT NOT NULL,
  PRIMARY KEY(local_task_id,forge,repository_id), UNIQUE(task_id,forge,repository_id),
  FOREIGN KEY(task_id,forge,repository_id) REFERENCES issue_mappings(task_id,forge,repository_id)
);
CREATE TABLE IF NOT EXISTS forge_event_cursors (
  forge TEXT NOT NULL, repository_id TEXT NOT NULL, subject_kind TEXT NOT NULL, subject_id TEXT NOT NULL,
  cursor_timestamp TEXT NOT NULL, cursor_tiebreaker TEXT NOT NULL, payload_hash TEXT NOT NULL,
  operation_id TEXT NOT NULL REFERENCES operations(operation_id), transition_kind TEXT NOT NULL,
  accepted_at TEXT NOT NULL,
  PRIMARY KEY(forge, repository_id, subject_kind, subject_id)
);
CREATE TRIGGER IF NOT EXISTS tasks_immutable_update BEFORE UPDATE ON tasks BEGIN SELECT RAISE(ABORT, 'tasks are immutable'); END;
CREATE TRIGGER IF NOT EXISTS tasks_immutable_delete BEFORE DELETE ON tasks BEGIN SELECT RAISE(ABORT, 'tasks are immutable'); END;
CREATE TRIGGER IF NOT EXISTS origin_transitions_append_only_update BEFORE UPDATE ON origin_transitions BEGIN SELECT RAISE(ABORT, 'origin transitions are append-only'); END;
CREATE TRIGGER IF NOT EXISTS origin_transitions_append_only_delete BEFORE DELETE ON origin_transitions BEGIN SELECT RAISE(ABORT, 'origin transitions are append-only'); END;
CREATE TRIGGER IF NOT EXISTS terminal_evidence_append_only_update BEFORE UPDATE ON terminal_evidence BEGIN SELECT RAISE(ABORT, 'terminal evidence is append-only'); END;
CREATE TRIGGER IF NOT EXISTS terminal_evidence_append_only_delete BEFORE DELETE ON terminal_evidence BEGIN SELECT RAISE(ABORT, 'terminal evidence is append-only'); END;
`;

function now() { return new Date().toISOString(); }
function originId() {
  let value = BigInt(`0x${randomBytes(16).toString("hex")}`);
  let encoded = "";
  for (let index = 0; index < 26; index += 1) {
    encoded = CROCKFORD[Number(value & 31n)] + encoded;
    value >>= 5n;
  }
  return `o${encoded}`;
}
function dbPath(env = process.env) {
  return canonicalizeSqliteDbPath(resolve(env.AIDEVOPS_TASK_COORDINATOR_DB ||
    join(env.HOME || homedir(), ".aidevops", ".agent-workspace", "coordinator", "tasks.db")));
}
function sqlite(path, input, { json = false } = {}) {
  const args = ["-batch", "-bail", "-cmd", ".timeout 15000"];
  if (json) args.push("-json");
  args.push(path);
  return execFileSync("sqlite3", args, { input, encoding: "utf8", timeout: 30000 }).trim();
}
function rows(path, query) {
  const raw = sqlite(path, query, { json: true });
  return raw ? JSON.parse(raw) : [];
}
function secureFile(path) {
  chmodSync(path, 0o600);
  return path;
}
function backup(path, reason) {
  if (!existsSync(path)) return "";
  if (!/^[a-z0-9-]{1,48}$/.test(reason)) throw new TypeError("invalid backup reason");
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("source database failed integrity verification");
  const target = `${path}-backup-${Date.now()}-${reason}.db`;
  sqlite(path, `.backup ${sqlEscape(target)}\n`);
  secureFile(target);
  if (sqlite(target, "PRAGMA integrity_check;\n") !== "ok") throw new Error("backup integrity verification failed");
  return target;
}
function migrateV1ToV2(path) {
  const copy = backup(path, "pre-migrate-v2");
  sqlite(path, `BEGIN IMMEDIATE;
ALTER TABLE operations ADD COLUMN result_hash TEXT NOT NULL DEFAULT 'unchecked';
ALTER TABLE restore_controls ADD COLUMN backup_high_water INTEGER NOT NULL DEFAULT 0;
UPDATE coordinator_meta SET value='2' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (2,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV2ToV3(path) {
  const copy = backup(path, "pre-migrate-v3");
  sqlite(path, `BEGIN IMMEDIATE;
${SCHEMA}
UPDATE coordinator_meta SET value='3' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (3,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV3ToV4(path) {
  const copy = backup(path, "pre-migrate-v4");
  sqlite(path, `BEGIN IMMEDIATE;
${SCHEMA}
UPDATE coordinator_meta SET value='4' WHERE key='schema_version';
INSERT OR IGNORE INTO coordinator_meta VALUES ('publication_fence','0');
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (4,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV4ToV5(path) {
  const copy = backup(path, "pre-migrate-v5");
  sqlite(path, `BEGIN IMMEDIATE;
${SCHEMA}
UPDATE coordinator_meta SET value='5' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (5,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV5ToV6(path) {
  const copy = backup(path, "pre-migrate-v6");
  sqlite(path, `BEGIN IMMEDIATE;
ALTER TABLE operations DROP COLUMN result_hash;
UPDATE coordinator_meta SET value='6' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (6,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV6ToV7(path) {
  const copy = backup(path, "pre-migrate-v7");
  sqlite(path, `BEGIN IMMEDIATE;
${SCHEMA}
UPDATE coordinator_meta SET value='7' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (7,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok") throw new Error("migration integrity verification failed");
}
function migrateV7ToV8(path) {
  const copy = backup(path, "pre-migrate-v8");
  sqlite(path, `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
${SCHEMA}
INSERT OR IGNORE INTO repository_task_aliases(local_task_id,forge,repository_id,task_id)
SELECT task_id,forge,repository_id,task_id FROM issue_mappings WHERE task_id GLOB 't[0-9]*';
UPDATE coordinator_meta SET value='8' WHERE key='schema_version';
INSERT INTO migration_history(version,applied_at,backup_path,integrity_result) VALUES (8,${sqlEscape(now())},${sqlEscape(copy)},'ok');
COMMIT;`);
  if (sqlite(path, "PRAGMA integrity_check;\n") !== "ok" || rows(path, "PRAGMA foreign_key_check;").length) throw new Error("migration integrity verification failed");
}
function migrate(path, version) {
  if (version === 1) {
    migrateV1ToV2(path);
    migrateV2ToV3(path);
    migrateV3ToV4(path);
    migrateV4ToV5(path);
    migrateV5ToV6(path);
    migrateV6ToV7(path);
  } else if (version === 2) {
    migrateV2ToV3(path);
    migrateV3ToV4(path);
    migrateV4ToV5(path);
    migrateV5ToV6(path);
    migrateV6ToV7(path);
  } else if (version === 3) {
    migrateV3ToV4(path);
    migrateV4ToV5(path);
    migrateV5ToV6(path);
    migrateV6ToV7(path);
  } else if (version === 4) {
    migrateV4ToV5(path);
    migrateV5ToV6(path);
    migrateV6ToV7(path);
  } else if (version === 5) {
    migrateV5ToV6(path);
    migrateV6ToV7(path);
  } else if (version === 6) migrateV6ToV7(path);
  else if (version !== 7 && version !== SCHEMA_VERSION) throw new Error(`unsupported coordinator schema ${version}`);
  if (version < 8) migrateV7ToV8(path);
}
function bootstrap(path) {
  const origin = originId();
  const token = randomUUID();
  const timestamp = now();
  sqlite(path, `PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; BEGIN IMMEDIATE; ${SCHEMA}
INSERT OR IGNORE INTO coordinator_meta VALUES ('schema_version','${SCHEMA_VERSION}');
INSERT OR IGNORE INTO coordinator_meta VALUES ('namespaced_emitted','0');
INSERT OR IGNORE INTO coordinator_meta VALUES ('publication_fence','0');
INSERT INTO origins SELECT ${sqlEscape(origin)},'active',0,1,${sqlEscape(token)},${sqlEscape(timestamp)} WHERE NOT EXISTS (SELECT 1 FROM origins);
INSERT INTO origin_transitions(origin_id,from_state,to_state,ownership_epoch,fencing_token,evidence_json,occurred_at)
SELECT origin_id,NULL,'active',ownership_epoch,fencing_token,'{}',${sqlEscape(timestamp)} FROM origins WHERE NOT EXISTS (SELECT 1 FROM origin_transitions);
INSERT INTO migration_history SELECT ${SCHEMA_VERSION},${sqlEscape(timestamp)},NULL,'ok' WHERE NOT EXISTS (SELECT 1 FROM migration_history); COMMIT;`);
}
function bootstrapLocked(path) {
  const lock = `${path}.init-lock`;
  const ownerToken = randomUUID();
  acquireInitializationLock(lock, ownerToken);
  try {
    if (!existsSync(path)) bootstrap(path);
    secureFile(path);
    const version = Number(sqlite(path, "SELECT value FROM coordinator_meta WHERE key='schema_version';\n"));
    if (!Number.isSafeInteger(version) || version < 1 || version > SCHEMA_VERSION) throw new Error(`unsupported coordinator schema ${version}`);
    migrate(path, version);
    secureFile(path);
  } finally {
    releaseInitializationLock(lock, ownerToken);
  }
}
function initialise(path = dbPath()) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  chmodSync(dirname(path), 0o700);
  bootstrapLocked(path);
  return path;
}
function activeOrigin(path) {
  const found = rows(path, "SELECT * FROM origins WHERE state='active' ORDER BY created_at DESC LIMIT 1;")[0];
  if (!found) throw new Error("no active allocation origin");
  return found;
}

export { SCHEMA_VERSION, activeOrigin, backup, dbPath, initialise, now, rows, secureFile, sqlite };
