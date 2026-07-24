// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Runtime-event evidence for the existing observability SQLite database.
 * Events are append-only evidence; they do not replace task, mailbox, audit,
 * transcript, or worker-metric authorities.
 */

import { randomUUID } from "node:crypto";
import { pathToFileURL } from "node:url";
import { runCli } from "./runtime-events-cli.mjs";
import { normaliseEventType, normaliseIdentifier } from "./runtime-events-identifiers.mjs";
import {
  RUNTIME_EVENT_PAYLOAD_MAX_BYTES,
  prepareRuntimePayload,
} from "./runtime-events-payload.mjs";
import {
  applyMergePatch,
  createMergePatch,
  jsonEqual,
  reconstructRuntimeState,
} from "./runtime-events-state.mjs";
import {
  RUNTIME_EVENTS_SCHEMA_SQL,
  currentStateRows,
  initialiseRuntimeEventStore,
  queryRuntimeEvents,
  queryWorkerLineage,
  resolveRuntimeEventsDbPath,
  verifyRuntimeEventStore,
} from "./runtime-events-store.mjs";
import {
  sqliteExec,
  sqliteExecSync,
  sqlEscape,
} from "./sqlite-process.mjs";
import {
  archiveRuntimeEvents,
  isProtectedRuntimeEvent,
  runtimeEventRetentionInventory,
  verifyRuntimeEventArchive,
} from "./runtime-events-retention.mjs";

export const RUNTIME_EVENT_ENVELOPE_VERSION = 1;
export {
  RUNTIME_EVENT_PAYLOAD_MAX_BYTES,
  RUNTIME_EVENTS_SCHEMA_SQL,
  applyMergePatch,
  createMergePatch,
  initialiseRuntimeEventStore,
  prepareRuntimePayload,
  queryRuntimeEvents,
  queryWorkerLineage,
  reconstructRuntimeState,
  resolveRuntimeEventsDbPath,
  verifyRuntimeEventStore,
  archiveRuntimeEvents,
  isProtectedRuntimeEvent,
  runtimeEventRetentionInventory,
  verifyRuntimeEventArchive,
};

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

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  runCli(process.argv.slice(2), {
    appendProjectedState,
    appendRuntimeEventSync,
    initialiseRuntimeEventStore,
    queryRuntimeEvents,
    queryWorkerLineage,
    verifyRuntimeEventStore,
  }).then(
    (code) => process.exitCode = code,
    (error) => {
      if (process.argv[2] !== "emit" && process.argv[2] !== "state") console.error(error.message);
      process.exitCode = process.argv[2] === "emit" || process.argv[2] === "state" ? 0 : 1;
    },
  );
}
