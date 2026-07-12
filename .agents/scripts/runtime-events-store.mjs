// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { normaliseEventType, normaliseIdentifier } from "./runtime-events-identifiers.mjs";
import { RUNTIME_EVENT_PAYLOAD_MAX_BYTES } from "./runtime-events-payload.mjs";
import { reconstructRuntimeState } from "./runtime-events-state.mjs";
import {
  canonicalizeSqliteDbPath,
  setDbPath,
  sqliteExecSync,
  sqlEscape,
} from "./sqlite-process.mjs";

export const RUNTIME_EVENTS_SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS runtime_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  envelope_version INTEGER NOT NULL CHECK(envelope_version = 1),
  occurred_at TEXT NOT NULL,
  event_id TEXT NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  causation_id TEXT,
  subject_id TEXT NOT NULL,
  session_id TEXT,
  worker_id TEXT,
  parent_worker_id TEXT,
  root_worker_id TEXT,
  root_event_id TEXT NOT NULL,
  parent_event_id TEXT,
  state_version INTEGER,
  payload_json TEXT NOT NULL,
  payload_bytes INTEGER NOT NULL CHECK(
    payload_bytes BETWEEN 2 AND ${RUNTIME_EVENT_PAYLOAD_MAX_BYTES}
    AND payload_bytes = length(CAST(payload_json AS BLOB))
  ),
  redaction_count INTEGER NOT NULL DEFAULT 0,
  CHECK(
    (event_type IN ('state.snapshot', 'state.delta') AND state_version IS NOT NULL)
    OR
    (event_type NOT IN ('state.snapshot', 'state.delta') AND state_version IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_runtime_events_subject_time
  ON runtime_events(subject_id, occurred_at, id);
CREATE INDEX IF NOT EXISTS idx_runtime_events_session_time
  ON runtime_events(session_id, occurred_at, id);
CREATE INDEX IF NOT EXISTS idx_runtime_events_correlation
  ON runtime_events(correlation_id, id);
CREATE INDEX IF NOT EXISTS idx_runtime_events_causation
  ON runtime_events(causation_id, id);
CREATE INDEX IF NOT EXISTS idx_runtime_events_worker
  ON runtime_events(worker_id, id);
CREATE INDEX IF NOT EXISTS idx_runtime_events_root_parent
  ON runtime_events(root_event_id, parent_event_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_runtime_events_subject_state_version
  ON runtime_events(subject_id, state_version)
  WHERE state_version IS NOT NULL;

CREATE TRIGGER IF NOT EXISTS runtime_events_reject_update
BEFORE UPDATE ON runtime_events
BEGIN
  SELECT RAISE(ABORT, 'runtime_events is append-only');
END;

CREATE TRIGGER IF NOT EXISTS runtime_events_reject_delete
BEFORE DELETE ON runtime_events
BEGIN
  SELECT RAISE(ABORT, 'runtime_events is append-only');
END;
`;

function queryJsonRows(sql, { executeSync = sqliteExecSync } = {}) {
  const raw = executeSync(`.mode json\n${sql}`, 15000);
  if (raw === null || raw === "") return [];
  const rows = JSON.parse(raw);
  return Array.isArray(rows) ? rows : [];
}

function runtimeEventSchemaReady() {
  const columns = new Set(queryJsonRows("PRAGMA table_info('runtime_events');").map((row) => row.name));
  const requiredColumns = [
    "envelope_version", "event_id", "event_type", "correlation_id", "causation_id",
    "subject_id", "session_id", "worker_id", "parent_worker_id", "root_worker_id",
    "root_event_id", "parent_event_id", "state_version", "payload_json", "payload_bytes",
    "redaction_count",
  ];
  if (!requiredColumns.every((column) => columns.has(column))) return false;
  const objects = queryJsonRows(`
    SELECT type, name FROM sqlite_master
    WHERE name IN (
      'runtime_events_reject_update', 'runtime_events_reject_delete',
      'idx_runtime_events_subject_state_version', 'idx_runtime_events_worker_lineage'
    );
  `);
  const names = new Set(objects.map((row) => row.name));
  return [
    "runtime_events_reject_update", "runtime_events_reject_delete",
    "idx_runtime_events_subject_state_version", "idx_runtime_events_worker_lineage",
  ].every((name) => names.has(name));
}

function addWorkerLineageColumns() {
  const columns = new Set(queryJsonRows("PRAGMA table_info('runtime_events');").map((row) => row.name));
  let migrated = true;
  for (const column of ["parent_worker_id", "root_worker_id"]) {
    if (!columns.has(column) && sqliteExecSync(`ALTER TABLE runtime_events ADD COLUMN ${column} TEXT;`, 15000) === null) {
      migrated = false;
    }
  }
  return migrated;
}

function migrateRuntimeEventSchema() {
  let migrated = sqliteExecSync(RUNTIME_EVENTS_SCHEMA_SQL, 15000) !== null;
  if (migrated) migrated = addWorkerLineageColumns();
  if (migrated) {
    migrated = sqliteExecSync(
      "CREATE INDEX IF NOT EXISTS idx_runtime_events_worker_lineage " +
      "ON runtime_events(root_worker_id, parent_worker_id, worker_id, id);",
      15000,
    ) !== null;
  }
  return migrated && runtimeEventSchemaReady();
}

/** Initialise the runtime-event table and migrate the two worker-lineage columns. */
export function initialiseRuntimeEventStore(dbPath = resolveRuntimeEventsDbPath()) {
  let initialized = false;
  try {
    const canonicalDbPath = canonicalizeSqliteDbPath(dbPath);
    mkdirSync(dirname(canonicalDbPath), { recursive: true });
    setDbPath(canonicalDbPath);
    initialized = runtimeEventSchemaReady() || migrateRuntimeEventSchema();
  } catch {
    initialized = false;
  }
  return initialized;
}

export function resolveRuntimeEventsDbPath(env = process.env) {
  const candidate = env.AIDEVOPS_OBS_DB_OVERRIDE || env.AIDEVOPS_RUNTIME_EVENTS_DB ||
    join(env.HOME || homedir(), ".aidevops", ".agent-workspace", "observability", "llm-requests.db");
  return canonicalizeSqliteDbPath(candidate);
}

export function queryRuntimeEvents(filters = {}, options = {}) {
  const clauses = [];
  if (filters.subjectId) clauses.push(`subject_id = ${sqlEscape(normaliseIdentifier(filters.subjectId, { required: true }))}`);
  if (filters.workerId) clauses.push(`worker_id = ${sqlEscape(normaliseIdentifier(filters.workerId, { required: true }))}`);
  if (filters.correlationId) clauses.push(`correlation_id = ${sqlEscape(normaliseIdentifier(filters.correlationId, { required: true }))}`);
  if (filters.eventType) clauses.push(`event_type = ${sqlEscape(normaliseEventType(filters.eventType))}`);
  const limit = Number.parseInt(String(filters.limit || 100), 10);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1000) throw new TypeError("query limit must be between 1 and 1000");
  const where = clauses.length > 0 ? `WHERE ${clauses.join(" AND ")}` : "";
  return queryJsonRows(`
    SELECT id, envelope_version, occurred_at, event_id, event_type,
      correlation_id, causation_id, subject_id, session_id, worker_id,
      parent_worker_id, root_worker_id, root_event_id, parent_event_id,
      state_version, payload_json, payload_bytes, redaction_count
    FROM runtime_events ${where} ORDER BY id DESC LIMIT ${limit};
  `, options);
}

export function queryWorkerLineage(workerId, { limit = 250 } = {}) {
  const normalized = normaliseIdentifier(workerId, { required: true });
  const boundedLimit = Number.parseInt(String(limit), 10);
  if (!Number.isSafeInteger(boundedLimit) || boundedLimit < 1 || boundedLimit > 1000) {
    throw new TypeError("lineage limit must be between 1 and 1000");
  }
  return queryJsonRows(`
    SELECT id, occurred_at, event_id, event_type, correlation_id, causation_id,
      subject_id, worker_id, parent_worker_id, root_worker_id, root_event_id,
      parent_event_id, state_version, payload_json
    FROM runtime_events
    WHERE worker_id = ${sqlEscape(normalized)}
       OR parent_worker_id = ${sqlEscape(normalized)}
       OR root_worker_id = ${sqlEscape(normalized)}
    ORDER BY id ASC LIMIT ${boundedLimit};
  `);
}

export function currentStateRows(subjectId, options = {}) {
  return queryJsonRows(`
    SELECT subject_id, event_type, state_version, payload_json
    FROM runtime_events
    WHERE subject_id = ${sqlEscape(subjectId)} AND state_version IS NOT NULL
    ORDER BY state_version ASC;
  `, options);
}

function runtimeStoreIsValid(result) {
  return [
    result.quickCheck === "ok",
    result.missingColumns.length === 0,
    result.triggerCount === 2,
    result.invalidPayloadRows === 0,
    result.invalidStateSubjects.length === 0,
  ].every(Boolean);
}

export function verifyRuntimeEventStore() {
  const quickCheck = sqliteExecSync("PRAGMA quick_check;", 15000);
  const columns = new Set(queryJsonRows("PRAGMA table_info('runtime_events');").map((row) => row.name));
  const requiredColumns = [
    "event_id", "event_type", "correlation_id", "subject_id", "worker_id",
    "parent_worker_id", "root_worker_id", "state_version", "payload_json",
  ];
  const missingColumns = requiredColumns.filter((column) => !columns.has(column));
  const triggerCount = Number(sqliteExecSync(`
    SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'
    AND name IN ('runtime_events_reject_update', 'runtime_events_reject_delete');
  `, 15000) || 0);
  const invalidPayloadRows = Number(sqliteExecSync(`
    SELECT COUNT(*) FROM runtime_events
    WHERE payload_bytes != length(CAST(payload_json AS BLOB)) OR json_valid(payload_json) = 0;
  `, 15000) || 0);
  const stateRows = queryJsonRows(`
    SELECT subject_id, event_type, state_version, payload_json
    FROM runtime_events WHERE state_version IS NOT NULL
    ORDER BY subject_id, state_version;
  `);
  const invalidStateSubjects = [];
  for (const subjectId of new Set(stateRows.map((row) => row.subject_id))) {
    try {
      reconstructRuntimeState(stateRows, { subjectId });
    } catch {
      invalidStateSubjects.push(subjectId);
    }
  }
  const result = {
    invalidPayloadRows,
    invalidStateSubjects,
    missingColumns,
    quickCheck,
    triggerCount,
  };
  result.ok = runtimeStoreIsValid(result);
  return Object.freeze(result);
}
