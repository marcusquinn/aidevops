// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Runtime-event evidence for the existing observability SQLite database.
 * Events are append-only evidence; they do not replace task, mailbox, audit,
 * transcript, or worker-metric authorities.
 */

import { createHash, randomUUID } from "node:crypto";
import {
  sqliteExec,
  sqliteExecSync,
  sqlEscape,
} from "../plugins/opencode-aidevops/observability-sqlite.mjs";

export const RUNTIME_EVENT_ENVELOPE_VERSION = 1;
export const RUNTIME_EVENT_PAYLOAD_MAX_BYTES = 16 * 1024;

const MAX_DEPTH = 8;
const MAX_KEYS = 128;
const MAX_ARRAY_ITEMS = 128;
const MAX_STRING_LENGTH = 2048;
const SAFE_ID_PATTERN = /^[A-Za-z0-9._:@#/-]+$/;
const SECRET_KEY_PATTERN = /^(auth|authorization|cookie|set_cookie|credentials?|password|passwd|secret|token|[a-z0-9]+_token|api_key|client_secret|private_key|database_url|dsn)$/i;
const PATH_KEY_PATTERN = /(^|_)(cwd|dir|directory|file|path|root|worktree)(_|$)/i;
const CREDENTIAL_PATTERN = /(^|[^A-Za-z0-9_-])(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;
const HOME_PATH_PATTERN = /(?:\/Users\/|\/home\/|[A-Za-z]:\\Users\\)[^\s"',}\]]+/g;
const PRIVATE_PATH_ID_PATTERN = /^(?:\/Users\/|\/home\/|[A-Za-z]:\\Users\\)/;

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
  if (!SAFE_ID_PATTERN.test(text) || PRIVATE_PATH_ID_PATTERN.test(text) || text.length > 256) {
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

function redactString(value, redactPaths, counters) {
  let result = value;
  result = result.replace(CREDENTIAL_PATTERN, (_match, boundary) => {
    counters.redactions++;
    return `${boundary}[redacted-credential]`;
  });
  result = result.replace(/\bBearer\s+[^\s,"']+/gi, () => {
    counters.redactions++;
    return "Bearer [redacted]";
  });
  result = result.replace(/(https?:\/\/)[^/@:\s]+:[^/@\s]+@/gi, (_match, scheme) => {
    counters.redactions++;
    return `${scheme}[redacted]@`;
  });
  if (redactPaths) {
    result = result.replace(HOME_PATH_PATTERN, () => {
      counters.redactions++;
      return "[redacted-path]";
    });
  }
  if (result.length > MAX_STRING_LENGTH) {
    counters.truncations++;
    result = `${result.slice(0, MAX_STRING_LENGTH)}[truncated]`;
  }
  return result;
}

function sanitizeValue(value, context, depth = 0, key = "") {
  const normalizedKey = key.replace(/([a-z0-9])([A-Z])/g, "$1_$2").replace(/-/g, "_");
  if (SECRET_KEY_PATTERN.test(normalizedKey)) {
    context.counters.redactions++;
    return "[redacted]";
  }
  if (context.redactPaths && PATH_KEY_PATTERN.test(key)) {
    context.counters.redactions++;
    return "[redacted-path]";
  }
  if (value === null || typeof value === "boolean" || typeof value === "number") {
    return Number.isFinite(value) || value === null || typeof value === "boolean" ? value : null;
  }
  if (typeof value === "string") return redactString(value, context.redactPaths, context.counters);
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
    output[objectKey] = sanitizeValue(value[objectKey], context, depth + 1, objectKey);
  }
  if (keys.length > MAX_KEYS) {
    context.counters.truncations++;
    output._truncated_keys = keys.length - MAX_KEYS;
  }
  return output;
}

/**
 * Redact and bound a payload before persistence.
 * State payloads additionally remove local path fields and home-directory paths.
 */
export function prepareRuntimePayload(payload, { redactPaths = false } = {}) {
  const counters = { redactions: 0, truncations: 0 };
  const value = sanitizeValue(payload ?? {}, {
    counters,
    redactPaths,
    seen: new WeakSet(),
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
export function createRuntimeEventEnvelope(input, { statePayload = false } = {}) {
  const eventId = normaliseIdentifier(input?.eventId || randomUUID(), { required: true });
  const sessionId = normaliseIdentifier(input?.sessionId || process.env.AIDEVOPS_SESSION_ID || process.env.OPENCODE_SESSION_ID);
  const workerId = normaliseIdentifier(
    input?.workerId || process.env.AIDEVOPS_WORKER_ID || process.env.WORKER_SESSION_KEY || process.env.WORKER_ISSUE_NUMBER,
  );
  const correlationId = normaliseIdentifier(input?.correlationId || sessionId || eventId, { required: true });
  const rootEventId = normaliseIdentifier(
    input?.rootEventId || process.env.AIDEVOPS_ROOT_EVENT_ID || eventId,
    { required: true },
  );
  const payload = prepareRuntimePayload(input?.payload, { redactPaths: statePayload });

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
    ${sqlEscape(envelope.rootEventId)},
    ${sqlEscape(envelope.parentEventId)},
    ${stateVersionSql},
    ${sqlEscape(envelope.payload.json)},
    ${envelope.payload.bytes},
    ${envelope.payload.redactionCount}`;
}

const RUNTIME_EVENT_COLUMNS = `(
  envelope_version, occurred_at, event_id, event_type, correlation_id,
  causation_id, subject_id, session_id, worker_id, root_event_id,
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

/** Build a BEGIN IMMEDIATE transaction that atomically allocates state_version. */
export function buildStateEventInsertSql(input, eventType) {
  if (eventType !== "state.snapshot" && eventType !== "state.delta") {
    throw new TypeError("state event type must be state.snapshot or state.delta");
  }
  const payloadKey = eventType === "state.snapshot" ? "state" : "patch";
  const envelope = createRuntimeEventEnvelope({
    ...input,
    eventType,
    payload: { [payloadKey]: input?.[payloadKey] },
  }, { statePayload: true });
  const nextVersionSql = `(
    SELECT COALESCE(MAX(state_version), 0) + 1
    FROM runtime_events
    WHERE subject_id = ${sqlEscape(envelope.subjectId)} AND state_version IS NOT NULL
  )`;
  return {
    envelope,
    sql: `BEGIN IMMEDIATE;
INSERT INTO runtime_events ${RUNTIME_EVENT_COLUMNS}
VALUES (${runtimeEventValuesSql(envelope, nextVersionSql)})
RETURNING state_version;
COMMIT;`,
  };
}

function appendStateEvent(input, eventType, { executeSync = sqliteExecSync } = {}) {
  try {
    const built = buildStateEventInsertSql(input, eventType);
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
