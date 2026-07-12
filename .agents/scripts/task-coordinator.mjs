#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash, randomBytes, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, renameSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { canonicalizeSqliteDbPath, sqlEscape } from "./sqlite-process.mjs";

const SCHEMA_VERSION = 3;
const PAYLOAD_MAX_BYTES = 64 * 1024;
const EVIDENCE_MAX_BYTES = 64 * 1024;
const CROCKFORD = "0123456789abcdefghjkmnpqrstvwxyz";
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const LEGACY_ID = /^t[1-9][0-9]{0,17}$/;
const TASK_ID = /^(?:t[1-9][0-9]{0,17}|to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]{0,17})$/;
const STATES = new Set(["active", "read-only", "redirected", "retired", "quarantined"]);
const RESULTS = new Set(["published", "retryable", "indeterminate", "terminal", "conflict"]);
const MAPPING_ROLES = new Set(["home", "implementation", "upstream"]);

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
  result_json TEXT NOT NULL CHECK(json_valid(result_json)), result_hash TEXT NOT NULL,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  CHECK(status IN ('published','retryable','indeterminate','terminal','conflict'))
);
CREATE TABLE IF NOT EXISTS publication_intents (
  intent_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES operations(operation_id),
  task_id TEXT NOT NULL REFERENCES tasks(task_id), payload_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), status TEXT NOT NULL DEFAULT 'retryable', created_at TEXT NOT NULL
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
CREATE TRIGGER IF NOT EXISTS tasks_immutable_update BEFORE UPDATE ON tasks BEGIN SELECT RAISE(ABORT, 'tasks are immutable'); END;
CREATE TRIGGER IF NOT EXISTS tasks_immutable_delete BEFORE DELETE ON tasks BEGIN SELECT RAISE(ABORT, 'tasks are immutable'); END;
CREATE TRIGGER IF NOT EXISTS origin_transitions_append_only_update BEFORE UPDATE ON origin_transitions BEGIN SELECT RAISE(ABORT, 'origin transitions are append-only'); END;
CREATE TRIGGER IF NOT EXISTS origin_transitions_append_only_delete BEFORE DELETE ON origin_transitions BEGIN SELECT RAISE(ABORT, 'origin transitions are append-only'); END;
CREATE TRIGGER IF NOT EXISTS terminal_evidence_append_only_update BEFORE UPDATE ON terminal_evidence BEGIN SELECT RAISE(ABORT, 'terminal evidence is append-only'); END;
CREATE TRIGGER IF NOT EXISTS terminal_evidence_append_only_delete BEFORE DELETE ON terminal_evidence BEGIN SELECT RAISE(ABORT, 'terminal evidence is append-only'); END;
`;

function now() { return new Date().toISOString(); }
function jsonText(value, label, maxBytes = PAYLOAD_MAX_BYTES) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new TypeError(`${label} must be a JSON object`);
  const text = JSON.stringify(value);
  if (Buffer.byteLength(text) > maxBytes) throw new TypeError(`${label} exceeds ${maxBytes} bytes`);
  return text;
}
function hashText(text) { return `sha256:${createHash("sha256").update(text).digest("hex")}`; }
function hashPayload(payload) { return hashText(jsonText(payload, "payload")); }
function validId(value, label) {
  if (typeof value !== "string" || !SAFE_ID.test(value)) throw new TypeError(`${label} is not a canonical opaque identifier`);
  return value;
}
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
ALTER TABLE operations ADD COLUMN result_hash TEXT NOT NULL DEFAULT 'sha256:unavailable';
ALTER TABLE restore_controls ADD COLUMN backup_high_water INTEGER NOT NULL DEFAULT 0;
UPDATE operations SET result_hash='sha3-256:'||lower(hex(sha3(result_json,256)));
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
function migrate(path, version) {
  if (version === 1) {
    migrateV1ToV2(path);
    migrateV2ToV3(path);
  } else if (version === 2) migrateV2ToV3(path);
  else if (version !== SCHEMA_VERSION) throw new Error(`unsupported coordinator schema ${version}`);
}
function bootstrap(path) {
  const origin = originId();
  const token = randomUUID();
  const timestamp = now();
  sqlite(path, `PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; BEGIN IMMEDIATE; ${SCHEMA}
INSERT OR IGNORE INTO coordinator_meta VALUES ('schema_version','${SCHEMA_VERSION}');
INSERT OR IGNORE INTO coordinator_meta VALUES ('namespaced_emitted','0');
INSERT INTO origins SELECT ${sqlEscape(origin)},'active',0,1,${sqlEscape(token)},${sqlEscape(timestamp)} WHERE NOT EXISTS (SELECT 1 FROM origins);
INSERT INTO origin_transitions(origin_id,from_state,to_state,ownership_epoch,fencing_token,evidence_json,occurred_at)
SELECT origin_id,NULL,'active',ownership_epoch,fencing_token,'{}',${sqlEscape(timestamp)} FROM origins WHERE NOT EXISTS (SELECT 1 FROM origin_transitions);
INSERT INTO migration_history SELECT ${SCHEMA_VERSION},${sqlEscape(timestamp)},NULL,'ok' WHERE NOT EXISTS (SELECT 1 FROM migration_history); COMMIT;`);
}
function initialise(path = dbPath()) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  chmodSync(dirname(path), 0o700);
  bootstrap(path);
  secureFile(path);
  const version = Number(sqlite(path, "SELECT value FROM coordinator_meta WHERE key='schema_version';\n"));
  if (!Number.isSafeInteger(version) || version < 1 || version > SCHEMA_VERSION) throw new Error(`unsupported coordinator schema ${version}`);
  migrate(path, version);
  bootstrap(path);
  secureFile(path);
  return path;
}
function activeOrigin(path) {
  const found = rows(path, "SELECT * FROM origins WHERE state='active' ORDER BY created_at DESC LIMIT 1;")[0];
  if (!found) throw new Error("no active allocation origin");
  return found;
}
function operationResult(path, operationId, payloadHash) {
  const existing = rows(path, `SELECT payload_hash,result_json,result_hash,'sha3-256:'||lower(hex(sha3(result_json,256))) AS computed_result_hash FROM operations WHERE operation_id=${sqlEscape(operationId)};`)[0];
  if (!existing) return null;
  if (existing.payload_hash !== payloadHash) throw new Error("operation_id payload conflict");
  if (!existing.result_json || existing.result_json === "{}" || existing.result_json === "null" || existing.computed_result_hash !== existing.result_hash) {
    throw new Error("operation result is incomplete or failed integrity verification");
  }
  return JSON.parse(existing.result_json);
}
function maybeCrash(phase) {
  if (process.env.AIDEVOPS_TASK_COORDINATOR_TEST_CRASH === phase) process.kill(process.pid, "SIGKILL");
}
function allocate({ operationId = randomUUID(), payload = {}, count = 1, legacyId = "" } = {}, path = initialise()) {
  validId(operationId, "operation_id");
  if (!Number.isSafeInteger(count) || count < 1 || count > 1000) throw new TypeError("count must be 1..1000");
  if (legacyId && !LEGACY_ID.test(legacyId)) throw new TypeError("legacy_id is not canonical");
  const legacyStart = legacyId ? Number(legacyId.slice(1)) : 0;
  if (legacyStart && legacyStart + count - 1 > 999999999999999999) throw new TypeError("legacy allocation exceeds lexical limit");
  const payloadText = jsonText(payload, "payload");
  const payloadHash = hashText(payloadText);
  const prior = operationResult(path, operationId, payloadHash);
  if (prior) return prior;
  const timestamp = now();
  maybeCrash("before-commit");
  try {
    sqlite(path, `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
INSERT INTO operations(operation_id,kind,task_id,payload_hash,payload_json,status,result_json,result_hash,created_at,updated_at)
VALUES (${sqlEscape(operationId)},'task.create',NULL,${sqlEscape(payloadHash)},${sqlEscape(payloadText)},'terminal','null','pending',${sqlEscape(timestamp)},${sqlEscape(timestamp)});
UPDATE origins SET sequence=sequence+${count} WHERE origin_id=(SELECT origin_id FROM origins WHERE state='active' ORDER BY created_at DESC LIMIT 1);
WITH RECURSIVE offsets(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM offsets WHERE n+1<${count})
INSERT INTO tasks(task_id,origin_id,sequence,parent_task_id,created_operation_id,payload_hash,payload_json,created_at)
SELECT CASE WHEN ${legacyStart}>0 THEN 't'||(${legacyStart}+n) ELSE 't'||o.origin_id||'-'||(o.sequence-${count}+1+n) END,
o.origin_id,o.sequence-${count}+1+n,NULL,${sqlEscape(operationId)},${sqlEscape(payloadHash)},${sqlEscape(payloadText)},${sqlEscape(timestamp)}
FROM origins o,offsets WHERE o.state='active';
UPDATE operations SET task_id=(SELECT task_id FROM tasks WHERE created_operation_id=${sqlEscape(operationId)} ORDER BY sequence LIMIT 1),
result_json=(SELECT json_object('operationId',${sqlEscape(operationId)},'tasks',json_group_array(json_object('taskId',task_id,'originId',origin_id,'sequence',sequence))) FROM (SELECT * FROM tasks WHERE created_operation_id=${sqlEscape(operationId)} ORDER BY sequence))
WHERE operation_id=${sqlEscape(operationId)};
UPDATE operations SET result_hash='sha3-256:'||lower(hex(sha3(result_json,256))) WHERE operation_id=${sqlEscape(operationId)};
UPDATE coordinator_meta SET value='1' WHERE key='namespaced_emitted' AND ${legacyStart}=0;
INSERT INTO terminal_evidence(operation_id,result_state,evidence_json,occurred_at) VALUES (${sqlEscape(operationId)},'terminal','{"allocation":"committed"}',${sqlEscape(timestamp)}); COMMIT;`);
  } catch (error) {
    const raced = operationResult(path, operationId, payloadHash);
    if (!raced) throw error;
    return raced;
  }
  maybeCrash("after-commit");
  return operationResult(path, operationId, payloadHash);
}
function publication({ operationId, taskId, payload = {} }, path = initialise()) {
  validId(operationId, "operation_id");
  if (!TASK_ID.test(taskId)) throw new TypeError("task_id is not canonical");
  const payloadText = jsonText(payload, "payload");
  const payloadHash = hashText(payloadText);
  const prior = operationResult(path, operationId, payloadHash);
  if (prior) return prior;
  const intentId = randomUUID();
  const timestamp = now();
  const result = { intentId, operationId, status: "retryable", taskId };
  const resultText = JSON.stringify(result);
  try {
    sqlite(path, `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
INSERT INTO operations VALUES (${sqlEscape(operationId)},'publication.intent',${sqlEscape(taskId)},${sqlEscape(payloadHash)},${sqlEscape(payloadText)},'retryable',${sqlEscape(resultText)},'sha3-256:'||lower(hex(sha3(${sqlEscape(resultText)},256))),${sqlEscape(timestamp)},${sqlEscape(timestamp)});
INSERT INTO publication_intents VALUES (${sqlEscape(intentId)},${sqlEscape(operationId)},${sqlEscape(taskId)},${sqlEscape(payloadHash)},${sqlEscape(payloadText)},'retryable',${sqlEscape(timestamp)}); COMMIT;`);
  } catch (error) {
    const raced = operationResult(path, operationId, payloadHash);
    if (!raced) throw error;
    return raced;
  }
  return result;
}
function attempt({ intentId, status, evidence = {} }, path = initialise()) {
  validId(intentId, "intent_id");
  if (!RESULTS.has(status)) throw new TypeError("invalid durable result state");
  const evidenceText = jsonText(evidence, "evidence", EVIDENCE_MAX_BYTES);
  const timestamp = now();
  sqlite(path, `PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;
INSERT INTO publication_attempts(intent_id,attempt_number,status,evidence_json,occurred_at)
SELECT ${sqlEscape(intentId)},COALESCE(MAX(attempt_number),0)+1,${sqlEscape(status)},${sqlEscape(evidenceText)},${sqlEscape(timestamp)} FROM publication_attempts WHERE intent_id=${sqlEscape(intentId)} HAVING EXISTS (SELECT 1 FROM publication_intents WHERE intent_id=${sqlEscape(intentId)});
CREATE TEMP TABLE assert_change(value INTEGER CHECK(value=1)); INSERT INTO assert_change VALUES(changes()); DROP TABLE assert_change;
UPDATE publication_intents SET status=${sqlEscape(status)} WHERE intent_id=${sqlEscape(intentId)};
UPDATE operations SET status=${sqlEscape(status)},updated_at=${sqlEscape(timestamp)},
result_json=json_object('intentId',${sqlEscape(intentId)},'operationId',operation_id,'status',${sqlEscape(status)},'taskId',task_id,'evidence',json(${sqlEscape(evidenceText)}))
WHERE operation_id=(SELECT operation_id FROM publication_intents WHERE intent_id=${sqlEscape(intentId)});
UPDATE operations SET result_hash='sha3-256:'||lower(hex(sha3(result_json,256))) WHERE operation_id=(SELECT operation_id FROM publication_intents WHERE intent_id=${sqlEscape(intentId)});
INSERT INTO terminal_evidence(operation_id,result_state,evidence_json,occurred_at)
SELECT operation_id,${sqlEscape(status)},${sqlEscape(evidenceText)},${sqlEscape(timestamp)} FROM publication_intents WHERE intent_id=${sqlEscape(intentId)} AND ${sqlEscape(status)} IN ('published','terminal','conflict'); COMMIT;`);
  return { intentId, status };
}
function transition({ state, evidence = {}, fencingToken }, path = initialise()) {
  if (!STATES.has(state)) throw new TypeError("invalid origin state");
  validId(fencingToken, "fencing_token");
  const evidenceText = jsonText(evidence, "evidence", EVIDENCE_MAX_BYTES);
  const origin = activeOrigin(path);
  if (fencingToken !== origin.fencing_token) throw new Error("stale fencing token");
  const timestamp = now();
  sqlite(path, `BEGIN IMMEDIATE; UPDATE origins SET state=${sqlEscape(state)} WHERE origin_id=${sqlEscape(origin.origin_id)} AND fencing_token=${sqlEscape(fencingToken)} AND state='active';
CREATE TEMP TABLE assert_change(value INTEGER CHECK(value=1)); INSERT INTO assert_change VALUES(changes()); DROP TABLE assert_change;
INSERT INTO origin_transitions(origin_id,from_state,to_state,ownership_epoch,fencing_token,evidence_json,occurred_at) VALUES (${sqlEscape(origin.origin_id)},${sqlEscape(origin.state)},${sqlEscape(state)},${origin.ownership_epoch},${sqlEscape(fencingToken)},${sqlEscape(evidenceText)},${sqlEscape(timestamp)}); COMMIT;`);
  return { originId: origin.origin_id, state };
}
function issueMappingInput(input) {
  const taskId = input.taskId;
  if (!TASK_ID.test(taskId)) throw new TypeError("task_id is not canonical");
  const forge = input.forge || "github";
  if (forge !== "github") throw new TypeError("unsupported forge");
  const repositoryId = validId(input.repositoryId, "repository_id");
  const repositorySlug = input.repositorySlug;
  if (typeof repositorySlug !== "string" || !/^[^/\s]+\/[^/\s]+$/.test(repositorySlug)) throw new TypeError("repository_slug is not canonical");
  const role = input.role || "home";
  if (!MAPPING_ROLES.has(role)) throw new TypeError("invalid issue mapping role");
  const issueId = validId(input.issueId, "issue_id");
  const projectId = input.projectId ? validId(input.projectId, "project_id") : null;
  const displayNumber = Number(input.displayNumber);
  if (!Number.isSafeInteger(displayNumber) || displayNumber < 1) throw new TypeError("display_number must be a positive integer");
  const stateCursor = input.stateCursor ? validId(input.stateCursor, "state_cursor") : null;
  const syncMetadataText = jsonText(input.syncMetadata || {}, "sync_metadata");
  return { taskId, forge, repositoryId, repositorySlug, role, issueId, projectId, displayNumber, stateCursor, syncMetadataText };
}
function bindIssue(input, path = initialise()) {
  const value = issueMappingInput(input);
  const timestamp = now();
  const existing = rows(path, `SELECT * FROM issue_mappings WHERE task_id=${sqlEscape(value.taskId)} AND forge=${sqlEscape(value.forge)} AND repository_id=${sqlEscape(value.repositoryId)};`)[0];
  if (existing && (existing.issue_id !== value.issueId || Number(existing.display_number) !== value.displayNumber || existing.role !== value.role)) {
    throw new Error("issue mapping conflict");
  }
  sqlite(path, `BEGIN IMMEDIATE;
INSERT INTO issue_mappings(task_id,forge,repository_id,repository_slug,role,issue_id,project_id,display_number,state_cursor,sync_metadata_json,created_at,updated_at)
VALUES (${sqlEscape(value.taskId)},${sqlEscape(value.forge)},${sqlEscape(value.repositoryId)},${sqlEscape(value.repositorySlug)},${sqlEscape(value.role)},${sqlEscape(value.issueId)},${sqlEscape(value.projectId)},${value.displayNumber},${sqlEscape(value.stateCursor)},${sqlEscape(value.syncMetadataText)},${sqlEscape(timestamp)},${sqlEscape(timestamp)})
ON CONFLICT(task_id,forge,repository_id) DO UPDATE SET repository_slug=excluded.repository_slug,project_id=COALESCE(excluded.project_id,issue_mappings.project_id),state_cursor=COALESCE(excluded.state_cursor,issue_mappings.state_cursor),sync_metadata_json=excluded.sync_metadata_json,updated_at=excluded.updated_at;
COMMIT;`);
  return resolveIssue({ taskId: value.taskId, forge: value.forge, repositoryId: value.repositoryId }, path);
}
function resolveIssue({ taskId, forge = "github", repositoryId }, path = initialise()) {
  if (!TASK_ID.test(taskId)) throw new TypeError("task_id is not canonical");
  validId(repositoryId, "repository_id");
  const matches = rows(path, `SELECT task_id AS taskId,forge,repository_id AS repositoryId,repository_slug AS repositorySlug,role,issue_id AS issueId,project_id AS projectId,display_number AS displayNumber,state_cursor AS stateCursor,sync_metadata_json AS syncMetadataJson FROM issue_mappings WHERE task_id=${sqlEscape(taskId)} AND forge=${sqlEscape(forge)} AND repository_id=${sqlEscape(repositoryId)};`);
  if (matches.length !== 1) throw new Error("issue mapping not found");
  return { ...matches[0], syncMetadata: JSON.parse(matches[0].syncMetadataJson) };
}
function validateRestoreEvidence(evidence, fencingToken) {
  const text = jsonText(evidence, "registry_evidence", EVIDENCE_MAX_BYTES);
  if (evidence.cas !== "winner" || evidence.prior_revoked !== true || evidence.fencing_token !== fencingToken || !validId(evidence.transfer_record_id, "transfer_record_id")) {
    throw new TypeError("registry evidence must prove CAS winner, prior revocation, transfer record, and returned fencing token");
  }
  return text;
}
function restore({ backupPath, registryEvidence, priorEpoch, newEpoch, fencingToken, publishedHighWater = 0 }, target = dbPath()) {
  validId(fencingToken, "fencing_token");
  if (!Number.isSafeInteger(priorEpoch) || priorEpoch < 1 || !Number.isSafeInteger(newEpoch) || newEpoch !== priorEpoch + 1) throw new TypeError("restore epoch must advance exactly once");
  if (!Number.isSafeInteger(publishedHighWater) || publishedHighWater < 0) throw new TypeError("published high-water must be a non-negative integer");
  const evidenceText = validateRestoreEvidence(registryEvidence, fencingToken);
  const canonicalBackup = canonicalizeSqliteDbPath(backupPath);
  if (!existsSync(canonicalBackup) || sqlite(canonicalBackup, "PRAGMA integrity_check;\n") !== "ok") throw new Error("restore backup failed integrity verification");
  const backupVersion = Number(sqlite(canonicalBackup, "SELECT value FROM coordinator_meta WHERE key='schema_version';\n"));
  if (backupVersion !== SCHEMA_VERSION) throw new Error("restore backup schema is not current");
  const restoredOrigin = rows(canonicalBackup, "SELECT * FROM origins ORDER BY created_at DESC LIMIT 1;")[0];
  if (!restoredOrigin || Number(restoredOrigin.ownership_epoch) !== priorEpoch) throw new Error("restore ownership epoch mismatch");
  const localHighWater = Number(sqlite(canonicalBackup, `SELECT MAX(v) FROM (SELECT sequence v FROM origins WHERE origin_id=${sqlEscape(restoredOrigin.origin_id)} UNION ALL SELECT COALESCE(MAX(sequence),0) FROM tasks WHERE origin_id=${sqlEscape(restoredOrigin.origin_id)});`));
  const highWater = Math.max(localHighWater, publishedHighWater);
  if (existsSync(target)) backup(target, "pre-restore");
  const staged = `${target}.restore-${process.pid}`;
  rmSync(staged, { force: true });
  sqlite(canonicalBackup, `.backup ${sqlEscape(staged)}\n`);
  secureFile(staged);
  const timestamp = now();
  sqlite(staged, `BEGIN IMMEDIATE; UPDATE origins SET state='active',sequence=${highWater},ownership_epoch=${newEpoch},fencing_token=${sqlEscape(fencingToken)} WHERE origin_id=${sqlEscape(restoredOrigin.origin_id)} AND ownership_epoch=${priorEpoch};
CREATE TEMP TABLE assert_change(value INTEGER CHECK(value=1)); INSERT INTO assert_change VALUES(changes()); DROP TABLE assert_change;
INSERT INTO restore_controls(origin_id,prior_epoch,new_epoch,fencing_token,registry_evidence_json,backup_integrity,backup_high_water,published_high_water,restored_at) VALUES (${sqlEscape(restoredOrigin.origin_id)},${priorEpoch},${newEpoch},${sqlEscape(fencingToken)},${sqlEscape(evidenceText)},'ok',${localHighWater},${publishedHighWater},${sqlEscape(timestamp)});
INSERT INTO origin_transitions(origin_id,from_state,to_state,ownership_epoch,fencing_token,evidence_json,occurred_at) VALUES (${sqlEscape(restoredOrigin.origin_id)},${sqlEscape(restoredOrigin.state)},'active',${newEpoch},${sqlEscape(fencingToken)},${sqlEscape(evidenceText)},${sqlEscape(timestamp)}); COMMIT;`);
  if (sqlite(staged, "PRAGMA integrity_check;\n") !== "ok") throw new Error("staged restore failed integrity verification");
  sqlite(target, "PRAGMA wal_checkpoint(TRUNCATE);\n");
  rmSync(`${target}-wal`, { force: true });
  rmSync(`${target}-shm`, { force: true });
  renameSync(staged, target);
  secureFile(target);
  return { originId: restoredOrigin.origin_id, sequence: highWater, ownershipEpoch: newEpoch };
}
function verify(path = initialise()) {
  const quickCheck = sqlite(path, "PRAGMA quick_check;\n");
  const foreignKeys = rows(path, "PRAGMA foreign_key_check;");
  const duplicateTasks = Number(sqlite(path, "SELECT COUNT(*) FROM (SELECT origin_id,sequence FROM tasks GROUP BY origin_id,sequence HAVING COUNT(*)>1);\n"));
  const incompleteOperations = Number(sqlite(path, "SELECT COUNT(*) FROM operations WHERE result_json IN ('{}','null') OR result_hash != 'sha3-256:'||lower(hex(sha3(result_json,256)));\n"));
  const result = { duplicateTasks, foreignKeyErrors: foreignKeys.length, incompleteOperations, quickCheck, schemaVersion: SCHEMA_VERSION };
  return { ...result, ok: quickCheck === "ok" && foreignKeys.length === 0 && duplicateTasks === 0 && incompleteOperations === 0 };
}

function parseJson(value = "{}") { return JSON.parse(value); }
function option(args, name, fallback = "") { const index = args.indexOf(name); return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback; }
export function run(args = process.argv.slice(2)) {
  const command = args[0] || "help";
  if (["help", "--help", "-h"].includes(command)) { process.stdout.write("Usage: task-coordinator.mjs allocate|publication-intent|attempt|transition|bind-issue|resolve-issue|restore|verify|status\n"); return 0; }
  const path = initialise();
  let result;
  if (command === "allocate") result = allocate({ operationId: option(args, "--operation-id") || randomUUID(), count: Number(option(args, "--count", "1")), legacyId: option(args, "--legacy-id"), payload: parseJson(option(args, "--payload", "{}")) }, path);
  else if (command === "publication-intent") result = publication({ operationId: option(args, "--operation-id"), taskId: option(args, "--task-id"), payload: parseJson(option(args, "--payload", "{}")) }, path);
  else if (command === "attempt") result = attempt({ intentId: option(args, "--intent-id"), status: option(args, "--status"), evidence: parseJson(option(args, "--evidence", "{}")) }, path);
  else if (command === "transition") result = transition({ state: option(args, "--state"), fencingToken: option(args, "--fencing-token"), evidence: parseJson(option(args, "--evidence", "{}")) }, path);
  else if (command === "bind-issue") result = bindIssue({ taskId: option(args, "--task-id"), forge: option(args, "--forge", "github"), repositoryId: option(args, "--repository-id"), repositorySlug: option(args, "--repository-slug"), role: option(args, "--role", "home"), issueId: option(args, "--issue-id"), projectId: option(args, "--project-id"), displayNumber: option(args, "--display-number"), stateCursor: option(args, "--state-cursor"), syncMetadata: parseJson(option(args, "--sync-metadata", "{}")) }, path);
  else if (command === "resolve-issue") result = resolveIssue({ taskId: option(args, "--task-id"), forge: option(args, "--forge", "github"), repositoryId: option(args, "--repository-id") }, path);
  else if (command === "restore") result = restore({ backupPath: option(args, "--backup"), registryEvidence: parseJson(option(args, "--registry-evidence", "{}")), priorEpoch: Number(option(args, "--prior-epoch")), newEpoch: Number(option(args, "--new-epoch")), fencingToken: option(args, "--fencing-token"), publishedHighWater: Number(option(args, "--published-high-water", "0")) }, path);
  else if (command === "verify") result = verify(path);
  else if (command === "status") result = { ...activeOrigin(path), dbPath: path };
  else throw new TypeError(`unknown task-coordinator command: ${command}`);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return result.ok === false ? 1 : 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try { process.exitCode = run(); } catch (error) { process.stderr.write(`task-coordinator: ${error.message}\n`); process.exitCode = 1; }
}

export { allocate, backup, bindIssue, hashPayload, initialise, resolveIssue, restore, verify };
