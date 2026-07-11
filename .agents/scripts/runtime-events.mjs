// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Runtime-event evidence for the existing observability SQLite database.
 * Events are append-only evidence; they do not replace task, mailbox, audit,
 * transcript, or worker-metric authorities.
 */

import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  canonicalizeSqliteDbPath,
  setDbPath,
  sqliteExec,
  sqliteExecSync,
  sqlEscape,
} from "./sqlite-process.mjs";

export const RUNTIME_EVENT_ENVELOPE_VERSION = 1;
export const RUNTIME_EVENT_PAYLOAD_MAX_BYTES = 16 * 1024;

const MAX_DEPTH = 8;
const MAX_KEYS = 128;
const MAX_ARRAY_ITEMS = 128;
const MAX_STRING_LENGTH = 2048;
const SAFE_ID_PATTERN = /^[A-Za-z0-9._:@#/-]+$/;
const SECRET_KEY_PATTERN = /^(auth|authorization|cookie|set_cookie|credentials?|password|passwd|secret|token|[a-z0-9]+_token|api_key|client_secret|private_key|database_url|dsn)$/i;
const PATH_KEY_PATTERN = /(^|_)(cwd|dir|directory|file|path|root|worktree)(_|$)/i;
const REPOSITORY_KEY_PATTERN = /^(project_name|repo|repository|repo_slug|repository_slug)$/i;
const CREDENTIAL_PATTERN = /(^|[^A-Za-z0-9_-])(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;
const AWS_ACCESS_KEY_PATTERN = /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g;
const AWS_SECRET_KEY_PATTERN = /\b[A-Za-z0-9/+=]{40}\b/g;
const JWT_PATTERN = /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g;
const BASIC_AUTH_PATTERN = /\bBasic\s+[A-Za-z0-9+/=_-]{8,}/gi;
const PEM_PATTERN = /-----BEGIN [A-Z0-9 ]+-----[\s\S]*?-----END [A-Z0-9 ]+-----/g;
const FILE_URL_PATTERN = /\bfile:\/\/\/[^\s"',)}\]]+/gi;
const ABSOLUTE_PATH_PATTERN = /(^|[\s("'=])(?:\/[^\s"',)}\]]+|[A-Za-z]:[\\/][^\s"',)}\]]+)/gm;
const PRIVATE_PATH_ID_PATTERN = /^(?:file:\/{2,3}|\/|[A-Za-z]:[\\/])/;
const REPOSITORY_LIKE_PATTERN = /\b[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\b/g;
const REPOSITORY_LIKE_ID_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const ORDINARY_PAYLOAD_KEYS = new Set([
  "call_id", "classification", "duration_ms", "error_type", "exit_code",
  "finish_reason", "model_id", "observation", "provider_id", "reason", "result",
  "role", "source", "status", "success", "tool_name",
]);

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

function hashIdentifier(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

function normaliseIdentifier(value, { required = false, fallback = "" } = {}) {
  const text = String(value ?? fallback).trim();
  if (!text) {
    if (required) throw new TypeError("runtime event identifier is required");
    return null;
  }
  if (!SAFE_ID_PATTERN.test(text) || PRIVATE_PATH_ID_PATTERN.test(text) ||
      REPOSITORY_LIKE_ID_PATTERN.test(text) || text.length > 256) {
    return hashIdentifier(text);
  }
  return text;
}

function normaliseEventType(value) {
  const eventType = String(value || "").trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]{0,127}$/.test(eventType)) {
    throw new TypeError("runtime event type must be a bounded dotted identifier");
  }
  return eventType;
}

function replaceSensitivePattern(value, pattern, replacement, counters) {
  return value.replace(pattern, (...args) => {
    counters.redactions++;
    return typeof replacement === "function" ? replacement(...args) : replacement;
  });
}

function configuredPrivateRoots() {
  const values = [process.env.HOME || homedir()];
  if (process.env.AIDEVOPS_PRIVATE_ROOTS) {
    values.push(...process.env.AIDEVOPS_PRIVATE_ROOTS.split(delimiter));
  }
  return values.filter((value) => value && value.startsWith("/"));
}

function redactString(value, redactPaths, counters, privateRoots) {
  let result = value;
  result = replaceSensitivePattern(result, CREDENTIAL_PATTERN,
    (_match, boundary) => `${boundary}[redacted-credential]`, counters);
  result = replaceSensitivePattern(result, AWS_ACCESS_KEY_PATTERN, "[redacted-aws-key]", counters);
  result = replaceSensitivePattern(result, AWS_SECRET_KEY_PATTERN, "[redacted-aws-secret]", counters);
  result = replaceSensitivePattern(result, JWT_PATTERN, "[redacted-jwt]", counters);
  result = replaceSensitivePattern(result, BASIC_AUTH_PATTERN, "Basic [redacted]", counters);
  result = replaceSensitivePattern(result, PEM_PATTERN, "[redacted-pem]", counters);
  result = replaceSensitivePattern(result, /\bBearer\s+[^\s,"']+/gi, "Bearer [redacted]", counters);
  result = replaceSensitivePattern(result, /(https?:\/\/)[^/@:\s]+:[^/@\s]+@/gi,
    (_match, scheme) => `${scheme}[redacted]@`, counters);
  for (const root of privateRoots) {
    if (!result.includes(root)) continue;
    counters.redactions++;
    result = result.split(root).join("[redacted-root]");
  }
  if (redactPaths) {
    result = replaceSensitivePattern(result, FILE_URL_PATTERN, "[redacted-file-url]", counters);
    result = replaceSensitivePattern(result, ABSOLUTE_PATH_PATTERN,
      (_match, boundary) => `${boundary}[redacted-path]`, counters);
  }
  result = replaceSensitivePattern(result, REPOSITORY_LIKE_PATTERN, "[redacted-repository]", counters);
  if (result.length > MAX_STRING_LENGTH) {
    counters.truncations++;
    result = `${result.slice(0, MAX_STRING_LENGTH)}[truncated]`;
  }
  return result;
}

function sanitizeValue(value, context, depth = 0, key = "") {
  const normalizedKey = key.replace(/([a-z0-9])([A-Z])/g, "$1_$2").replace(/-/g, "_");
  // Preserve merge-patch deletion sentinels. Null contains no sensitive value,
  // and replacing it would turn a requested deletion into persisted state.
  if (value === null) return null;
  if (SECRET_KEY_PATTERN.test(normalizedKey)) {
    context.counters.redactions++;
    return "[redacted]";
  }
  if (context.redactPaths && (PATH_KEY_PATTERN.test(normalizedKey) || REPOSITORY_KEY_PATTERN.test(normalizedKey))) {
    context.counters.redactions++;
    return PATH_KEY_PATTERN.test(normalizedKey) ? "[redacted-path]" : "[redacted-repository]";
  }
  if (typeof value === "boolean" || typeof value === "number") {
    return Number.isFinite(value) || typeof value === "boolean" ? value : null;
  }
  if (typeof value === "string") {
    return redactString(value, context.redactPaths, context.counters, context.privateRoots);
  }
  if (typeof value === "bigint") return value.toString();
  if (typeof value !== "object") return null;
  if (depth >= MAX_DEPTH) {
    context.counters.truncations++;
    return "[max-depth]";
  }
  if (context.seen.has(value)) {
    context.counters.truncations++;
    return "[circular]";
  }
  context.seen.add(value);

  if (Array.isArray(value)) {
    const items = value.slice(0, MAX_ARRAY_ITEMS)
      .map((item) => sanitizeValue(item, context, depth + 1, ""));
    if (value.length > MAX_ARRAY_ITEMS) {
      context.counters.truncations++;
      items.push("[truncated-items]");
    }
    return items;
  }

  const output = {};
  const keys = Object.keys(value).sort();
  for (const objectKey of keys.slice(0, MAX_KEYS)) {
    if (depth === 0 && context.strictTopLevel && !ORDINARY_PAYLOAD_KEYS.has(objectKey)) {
      context.counters.redactions++;
      continue;
    }
    output[objectKey] = sanitizeValue(value[objectKey], context, depth + 1, objectKey);
  }
  if (keys.length > MAX_KEYS) {
    context.counters.truncations++;
    output._truncated_keys = keys.length - MAX_KEYS;
  }
  return output;
}

/**
 * Redact and bound a payload before persistence. Runtime envelopes remove
 * repository/path fields and home-directory paths before they reach SQLite.
 */
export function prepareRuntimePayload(payload, { redactPaths = true, strictTopLevel = true } = {}) {
  const counters = { redactions: 0, truncations: 0 };
  const value = sanitizeValue(payload ?? {}, {
    counters,
    privateRoots: configuredPrivateRoots(),
    redactPaths,
    seen: new WeakSet(),
    strictTopLevel,
  });
  let json = JSON.stringify(value);
  let bytes = Buffer.byteLength(json, "utf8");
  if (bytes > RUNTIME_EVENT_PAYLOAD_MAX_BYTES) {
    counters.truncations++;
    const marker = {
      _original_bytes: bytes,
      _truncated: true,
    };
    const stateKey = redactPaths && isJsonObject(value)
      ? ["state", "patch"].find((candidate) => Object.hasOwn(value, candidate))
      : null;
    json = JSON.stringify(stateKey ? { [stateKey]: marker } : marker);
    bytes = Buffer.byteLength(json, "utf8");
  }
  return {
    bytes,
    json,
    redactionCount: counters.redactions,
    truncated: counters.truncations > 0,
    value: JSON.parse(json),
  };
}

function normaliseOccurredAt(value) {
  const date = value ? new Date(value) : new Date();
  if (Number.isNaN(date.getTime())) throw new TypeError("runtime event occurredAt must be a valid date");
  return date.toISOString();
}

/** Build a validated, redacted runtime-event envelope without writing it. */
export function createRuntimeEventEnvelope(input, { redactPaths = true, strictTopLevel = true } = {}) {
  const eventId = normaliseIdentifier(input?.eventId || randomUUID(), { required: true });
  const sessionId = normaliseIdentifier(input?.sessionId || process.env.AIDEVOPS_SESSION_ID || process.env.OPENCODE_SESSION_ID);
  const workerId = normaliseIdentifier(
    input?.workerId || process.env.AIDEVOPS_WORKER_ID || process.env.WORKER_SESSION_KEY || process.env.WORKER_ISSUE_NUMBER,
  );
  const parentWorkerId = normaliseIdentifier(
    input?.parentWorkerId || process.env.AIDEVOPS_PARENT_WORKER_ID,
  );
  const rootWorkerId = normaliseIdentifier(
    input?.rootWorkerId || process.env.AIDEVOPS_ROOT_WORKER_ID || workerId,
  );
  const correlationId = normaliseIdentifier(
    input?.correlationId || process.env.AIDEVOPS_CORRELATION_ID || sessionId || eventId,
    { required: true },
  );
  const rootEventId = normaliseIdentifier(
    input?.rootEventId || process.env.AIDEVOPS_ROOT_EVENT_ID || eventId,
    { required: true },
  );
  const payload = prepareRuntimePayload(input?.payload, { redactPaths, strictTopLevel });

  return Object.freeze({
    envelopeVersion: RUNTIME_EVENT_ENVELOPE_VERSION,
    occurredAt: normaliseOccurredAt(input?.occurredAt),
    eventId,
    eventType: normaliseEventType(input?.eventType),
    correlationId,
    causationId: normaliseIdentifier(input?.causationId || process.env.AIDEVOPS_CAUSATION_ID),
    subjectId: normaliseIdentifier(input?.subjectId, { required: true }),
    sessionId,
    workerId,
    parentWorkerId,
    rootWorkerId,
    rootEventId,
    parentEventId: normaliseIdentifier(input?.parentEventId || process.env.AIDEVOPS_PARENT_EVENT_ID),
    payload,
  });
}

function runtimeEventValuesSql(envelope, stateVersionSql = "NULL") {
  return `
    ${envelope.envelopeVersion},
    ${sqlEscape(envelope.occurredAt)},
    ${sqlEscape(envelope.eventId)},
    ${sqlEscape(envelope.eventType)},
    ${sqlEscape(envelope.correlationId)},
    ${sqlEscape(envelope.causationId)},
    ${sqlEscape(envelope.subjectId)},
    ${sqlEscape(envelope.sessionId)},
    ${sqlEscape(envelope.workerId)},
    ${sqlEscape(envelope.parentWorkerId)},
    ${sqlEscape(envelope.rootWorkerId)},
    ${sqlEscape(envelope.rootEventId)},
    ${sqlEscape(envelope.parentEventId)},
    ${stateVersionSql},
    ${sqlEscape(envelope.payload.json)},
    ${envelope.payload.bytes},
    ${envelope.payload.redactionCount}`;
}

const RUNTIME_EVENT_COLUMNS = `(
  envelope_version, occurred_at, event_id, event_type, correlation_id,
  causation_id, subject_id, session_id, worker_id, parent_worker_id,
  root_worker_id, root_event_id,
  parent_event_id, state_version, payload_json, payload_bytes, redaction_count
)`;

/** Build an INSERT for a non-state runtime event. */
export function buildRuntimeEventInsertSql(input) {
  const envelope = createRuntimeEventEnvelope(input);
  if (envelope.eventType === "state.snapshot" || envelope.eventType === "state.delta") {
    throw new TypeError("state events require transactional state-version allocation");
  }
  return {
    envelope,
    sql: `INSERT INTO runtime_events ${RUNTIME_EVENT_COLUMNS} VALUES (${runtimeEventValuesSql(envelope)});`,
  };
}

/**
 * Append ordinary evidence without affecting runtime execution on failure.
 * The asynchronous SQLite queue is intentionally fire-and-forget.
 */
export function appendRuntimeEvent(input, { execute = sqliteExec } = {}) {
  try {
    const built = buildRuntimeEventInsertSql(input);
    execute(built.sql);
    return built.envelope;
  } catch {
    return null;
  }
}

/** Append ordinary evidence synchronously for short-lived CLI callers. */
export function appendRuntimeEventSync(input, { executeSync = sqliteExecSync } = {}) {
  try {
    const built = buildRuntimeEventInsertSql(input);
    if (executeSync(built.sql, 15000) === null) return null;
    return built.envelope;
  } catch {
    return null;
  }
}

/** Build a transaction that optionally enforces an optimistic base version. */
export function buildStateEventInsertSql(input, eventType, { expectedVersion } = {}) {
  if (eventType !== "state.snapshot" && eventType !== "state.delta") {
    throw new TypeError("state event type must be state.snapshot or state.delta");
  }
  const payloadKey = eventType === "state.snapshot" ? "state" : "patch";
  const envelope = createRuntimeEventEnvelope({
    ...input,
    eventType,
    payload: { [payloadKey]: input?.[payloadKey] },
  }, { redactPaths: true, strictTopLevel: false });
  const currentVersionSql = `COALESCE((
    SELECT MAX(state_version) FROM runtime_events
    WHERE subject_id = ${sqlEscape(envelope.subjectId)} AND state_version IS NOT NULL
  ), 0)`;
  const hasExpectedVersion = expectedVersion !== undefined;
  if (hasExpectedVersion && (!Number.isSafeInteger(expectedVersion) || expectedVersion < 0)) {
    throw new TypeError("expected state version must be a non-negative safe integer");
  }
  const nextVersionSql = hasExpectedVersion ? String(expectedVersion + 1) : `(${currentVersionSql} + 1)`;
  const insertSql = hasExpectedVersion
    ? `INSERT INTO runtime_events ${RUNTIME_EVENT_COLUMNS}
SELECT ${runtimeEventValuesSql(envelope, nextVersionSql)}
WHERE ${currentVersionSql} = ${expectedVersion}`
    : `INSERT INTO runtime_events ${RUNTIME_EVENT_COLUMNS}
VALUES (${runtimeEventValuesSql(envelope, nextVersionSql)})`;
  return {
    envelope,
    sql: `BEGIN IMMEDIATE;
${insertSql}
RETURNING state_version;
COMMIT;`,
  };
}

function appendStateEvent(input, eventType, { executeSync = sqliteExecSync, expectedVersion } = {}) {
  try {
    const built = buildStateEventInsertSql(input, eventType, { expectedVersion });
    const result = executeSync(built.sql, 15000);
    if (result === null) return null;
    const stateVersion = Number.parseInt(String(result).trim().split(/\s+/).at(-1), 10);
    if (!Number.isSafeInteger(stateVersion) || stateVersion < 1) return null;
    return Object.freeze({ ...built.envelope, stateVersion });
  } catch {
    return null;
  }
}

export function appendStateSnapshot(input, options) {
  return appendStateEvent(input, "state.snapshot", options);
}

export function appendStateDelta(input, options) {
  return appendStateEvent(input, "state.delta", options);
}

function isJsonObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function canonicalClone(value) {
  if (Array.isArray(value)) return value.map(canonicalClone);
  if (!isJsonObject(value)) return value;
  const output = {};
  for (const key of Object.keys(value).sort()) output[key] = canonicalClone(value[key]);
  return output;
}

function jsonEqual(left, right) {
  return JSON.stringify(canonicalClone(left)) === JSON.stringify(canonicalClone(right));
}

/** Apply RFC 7396 JSON Merge Patch and return canonical key ordering. */
export function applyMergePatch(target, patch) {
  if (!isJsonObject(patch)) return canonicalClone(patch);
  const output = isJsonObject(target) ? canonicalClone(target) : {};
  for (const key of Object.keys(patch).sort()) {
    if (patch[key] === null) delete output[key];
    else output[key] = applyMergePatch(output[key], patch[key]);
  }
  return canonicalClone(output);
}

function parseStatePayload(row) {
  const payload = typeof row.payload_json === "string"
    ? JSON.parse(row.payload_json)
    : row.payload_json;
  if (!isJsonObject(payload)) throw new TypeError("state event payload must be an object");
  return payload;
}

/**
 * Reconstruct bounded state from an ordered or unordered set of event rows.
 * The latest snapshot at or before targetVersion is the base; later deltas use
 * RFC 7396 merge-patch semantics in strictly increasing state-version order.
 */
export function reconstructRuntimeState(rows, { subjectId, targetVersion = Number.MAX_SAFE_INTEGER } = {}) {
  const events = rows
    .filter((row) => !subjectId || row.subject_id === subjectId)
    .filter((row) => Number.isSafeInteger(Number(row.state_version)) && Number(row.state_version) >= 1)
    .filter((row) => Number(row.state_version) <= targetVersion)
    .sort((a, b) => Number(a.state_version) - Number(b.state_version));
  for (let index = 1; index < events.length; index++) {
    if (Number(events[index - 1].state_version) === Number(events[index].state_version)) {
      throw new Error("state event versions must be unique");
    }
  }
  let snapshotIndex = -1;
  for (let index = 0; index < events.length; index++) {
    if (events[index].event_type === "state.snapshot") snapshotIndex = index;
  }
  if (snapshotIndex < 0) throw new Error("state reconstruction requires a snapshot");

  const snapshot = events[snapshotIndex];
  const snapshotPayload = parseStatePayload(snapshot);
  if (!("state" in snapshotPayload)) throw new Error("state snapshot payload is missing state");
  let state = canonicalClone(snapshotPayload.state);
  let version = Number(snapshot.state_version);

  for (const event of events.slice(snapshotIndex + 1)) {
    const nextVersion = Number(event.state_version);
    if (nextVersion !== version + 1) throw new Error("state event versions are not contiguous");
    const payload = parseStatePayload(event);
    if (event.event_type === "state.snapshot") {
      if (!("state" in payload)) throw new Error("state snapshot payload is missing state");
      state = canonicalClone(payload.state);
    } else if (event.event_type === "state.delta") {
      if (!("patch" in payload)) throw new Error("state delta payload is missing patch");
      state = applyMergePatch(state, payload.patch);
    } else {
      throw new Error(`unsupported state event type: ${event.event_type}`);
    }
    version = nextVersion;
  }

  return Object.freeze({ state: canonicalClone(state), stateVersion: version });
}

/** Build the smallest RFC 7396 patch that transforms current into next. */
export function createMergePatch(current, next) {
  if (jsonEqual(current, next)) return isJsonObject(next) ? {} : canonicalClone(next);
  if (!isJsonObject(current) || !isJsonObject(next)) return canonicalClone(next);
  const patch = {};
  const keys = new Set([...Object.keys(current), ...Object.keys(next)]);
  for (const key of [...keys].sort()) {
    if (!Object.hasOwn(next, key)) {
      patch[key] = null;
    } else if (!Object.hasOwn(current, key)) {
      patch[key] = canonicalClone(next[key]);
    } else {
      if (jsonEqual(current[key], next[key])) continue;
      const childPatch = createMergePatch(current[key], next[key]);
      if (!isJsonObject(childPatch) || Object.keys(childPatch).length > 0) patch[key] = childPatch;
    }
  }
  return patch;
}

export function resolveRuntimeEventsDbPath(env = process.env) {
  const candidate = env.AIDEVOPS_OBS_DB_OVERRIDE || env.AIDEVOPS_RUNTIME_EVENTS_DB ||
    join(env.HOME || homedir(), ".aidevops", ".agent-workspace", "observability", "llm-requests.db");
  return canonicalizeSqliteDbPath(candidate);
}

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

/** Initialise the runtime-event table and migrate the two worker-lineage columns. */
export function initialiseRuntimeEventStore(dbPath = resolveRuntimeEventsDbPath()) {
  try {
    const canonicalDbPath = canonicalizeSqliteDbPath(dbPath);
    mkdirSync(dirname(canonicalDbPath), { recursive: true });
    setDbPath(canonicalDbPath);
    if (runtimeEventSchemaReady()) return true;
    if (sqliteExecSync(RUNTIME_EVENTS_SCHEMA_SQL, 15000) === null) return false;
    const columns = new Set(queryJsonRows("PRAGMA table_info('runtime_events');").map((row) => row.name));
    for (const column of ["parent_worker_id", "root_worker_id"]) {
      if (!columns.has(column) && sqliteExecSync(`ALTER TABLE runtime_events ADD COLUMN ${column} TEXT;`, 15000) === null) {
        return false;
      }
    }
    if (sqliteExecSync(
      "CREATE INDEX IF NOT EXISTS idx_runtime_events_worker_lineage " +
      "ON runtime_events(root_worker_id, parent_worker_id, worker_id, id);",
      15000,
    ) === null) return false;
    return runtimeEventSchemaReady();
  } catch {
    return false;
  }
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

function currentStateRows(subjectId, options = {}) {
  return queryJsonRows(`
    SELECT subject_id, event_type, state_version, payload_json
    FROM runtime_events
    WHERE subject_id = ${sqlEscape(subjectId)} AND state_version IS NOT NULL
    ORDER BY state_version ASC;
  `, options);
}

function sanitizedProjectedState(state) {
  return prepareRuntimePayload({ state }, { redactPaths: true, strictTopLevel: false }).value.state;
}

export function appendProjectedState(input, mode = "auto", options = {}) {
  const subjectId = normaliseIdentifier(input?.subjectId, { required: true });
  const nextState = input?.state;
  if (mode === "snapshot") return appendStateSnapshot({ ...input, subjectId, state: nextState }, options);
  if (mode === "delta") return appendStateDelta({ ...input, subjectId, patch: nextState }, options);
  if (mode !== "auto") throw new TypeError("state mode must be snapshot, delta, or auto");
  const desiredState = sanitizedProjectedState(nextState);

  for (let attempt = 0; attempt < 20; attempt++) {
    const rows = currentStateRows(subjectId, options);
    const current = rows.length === 0
      ? { state: undefined, stateVersion: 0 }
      : reconstructRuntimeState(rows, { subjectId });
    if (rows.length > 0 && jsonEqual(current.state, desiredState)) return null;

    let eventType = "state.snapshot";
    let eventInput = { ...input, subjectId, state: desiredState };
    if (rows.length > 0) {
      const patch = createMergePatch(current.state, desiredState);
      if (jsonEqual(applyMergePatch(current.state, patch), desiredState)) {
        eventType = "state.delta";
        eventInput = { ...input, subjectId, patch };
      }
    }

    const envelope = appendStateEvent(eventInput, eventType, {
      ...options,
      expectedVersion: current.stateVersion,
    });
    if (envelope) return envelope;
  }
  return null;
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
  for (const subjectId of [...new Set(stateRows.map((row) => row.subject_id))]) {
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
    ok: quickCheck === "ok" && missingColumns.length === 0 && triggerCount === 2 &&
      invalidPayloadRows === 0 && invalidStateSubjects.length === 0,
    quickCheck,
    triggerCount,
  };
  return Object.freeze(result);
}

function optionValue(args, name, fallback = "") {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback;
}

function readJsonInput(value) {
  const text = !value || value === "-" ? readFileSync(0, "utf8") : value;
  return JSON.parse(text);
}

function cliSubject(args) {
  return optionValue(args, "--subject") || process.env.AIDEVOPS_WORKER_ID || process.env.AIDEVOPS_SESSION_ID;
}

function printJson(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

async function runCli(args) {
  const command = args[0] || "help";
  if (command === "help" || command === "--help" || command === "-h") {
    process.stdout.write("Usage: runtime-events.mjs emit|state|query|lineage|verify [options]\n");
    return 0;
  }
  if (!initialiseRuntimeEventStore()) return command === "emit" || command === "state" ? 0 : 1;
  if (command === "emit") {
    const eventType = args[1];
    const status = optionValue(args, "--status");
    const source = optionValue(args, "--source");
    const classification = optionValue(args, "--classification");
    const payloadText = optionValue(args, "--payload");
    let payload = payloadText ? JSON.parse(payloadText) : {};
    if (status) payload = { ...payload, status };
    if (source) payload = { ...payload, source };
    if (classification) payload = { ...payload, classification };
    const generatedEventId = args.includes("--root-dispatch")
      ? optionValue(args, "--event-id") || randomUUID()
      : optionValue(args, "--event-id") || undefined;
    const envelope = appendRuntimeEventSync({
      eventId: generatedEventId,
      eventType,
      subjectId: cliSubject(args),
      workerId: optionValue(args, "--worker") || undefined,
      parentWorkerId: optionValue(args, "--parent-worker") || undefined,
      rootWorkerId: optionValue(args, "--root-worker") || undefined,
      correlationId: optionValue(args, "--correlation") || undefined,
      causationId: optionValue(args, "--causation") || undefined,
      rootEventId: optionValue(args, "--root-event") ||
        (args.includes("--root-dispatch") ? process.env.AIDEVOPS_ROOT_EVENT_ID || generatedEventId : undefined),
      parentEventId: optionValue(args, "--parent-event") || undefined,
      payload,
    });
    if (envelope) {
      if (args.includes("--print-id")) process.stdout.write(`${envelope.eventId}\n`);
      else printJson(envelope);
    }
    return 0;
  }
  if (command === "state") {
    const mode = args[1] || "auto";
    const subjectId = args[2];
    const state = readJsonInput(args[3]);
    const envelope = appendProjectedState({ subjectId, state }, mode);
    if (envelope) printJson(envelope);
    return 0;
  }
  if (command === "query") {
    printJson(queryRuntimeEvents({
      correlationId: optionValue(args, "--correlation"),
      eventType: optionValue(args, "--type"),
      limit: optionValue(args, "--limit", "100"),
      subjectId: optionValue(args, "--subject"),
      workerId: optionValue(args, "--worker"),
    }));
    return 0;
  }
  if (command === "lineage") {
    printJson(queryWorkerLineage(args[1], { limit: optionValue(args, "--limit", "250") }));
    return 0;
  }
  if (command === "verify") {
    const result = verifyRuntimeEventStore();
    printJson(result);
    return result.ok ? 0 : 1;
  }
  throw new TypeError(`unknown runtime-events command: ${command}`);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  runCli(process.argv.slice(2)).then(
    (code) => process.exitCode = code,
    (error) => {
      if (process.argv[2] !== "emit" && process.argv[2] !== "state") console.error(error.message);
      process.exitCode = process.argv[2] === "emit" || process.argv[2] === "state" ? 0 : 1;
    },
  );
}
