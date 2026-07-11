// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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

export function jsonEqual(left, right) {
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

function orderedStateEvents(rows, subjectId, targetVersion) {
  return rows
    .filter((row) => !subjectId || row.subject_id === subjectId)
    .filter((row) => Number.isSafeInteger(Number(row.state_version)) && Number(row.state_version) >= 1)
    .filter((row) => Number(row.state_version) <= targetVersion)
    .sort((a, b) => Number(a.state_version) - Number(b.state_version));
}

function assertUniqueStateVersions(events) {
  for (let index = 1; index < events.length; index++) {
    if (Number(events[index - 1].state_version) === Number(events[index].state_version)) {
      throw new Error("state event versions must be unique");
    }
  }
}

function latestSnapshotIndex(events) {
  let snapshotIndex = -1;
  for (let index = 0; index < events.length; index++) {
    if (events[index].event_type === "state.snapshot") snapshotIndex = index;
  }
  if (snapshotIndex < 0) throw new Error("state reconstruction requires a snapshot");
  return snapshotIndex;
}

function stateFromEvent(currentState, event) {
  const payload = parseStatePayload(event);
  let state;
  if (event.event_type === "state.snapshot") {
    if (!("state" in payload)) throw new Error("state snapshot payload is missing state");
    state = canonicalClone(payload.state);
  } else if (event.event_type === "state.delta") {
    if (!("patch" in payload)) throw new Error("state delta payload is missing patch");
    state = applyMergePatch(currentState, payload.patch);
  } else {
    throw new Error(`unsupported state event type: ${event.event_type}`);
  }
  return state;
}

/** Reconstruct state from the latest snapshot and its contiguous deltas. */
export function reconstructRuntimeState(rows, { subjectId, targetVersion = Number.MAX_SAFE_INTEGER } = {}) {
  const events = orderedStateEvents(rows, subjectId, targetVersion);
  assertUniqueStateVersions(events);
  const snapshotIndex = latestSnapshotIndex(events);
  const snapshot = events[snapshotIndex];
  const snapshotPayload = parseStatePayload(snapshot);
  if (!("state" in snapshotPayload)) throw new Error("state snapshot payload is missing state");
  let state = canonicalClone(snapshotPayload.state);
  let version = Number(snapshot.state_version);

  for (const event of events.slice(snapshotIndex + 1)) {
    const nextVersion = Number(event.state_version);
    if (nextVersion !== version + 1) throw new Error("state event versions are not contiguous");
    state = stateFromEvent(state, event);
    version = nextVersion;
  }

  return Object.freeze({ state: canonicalClone(state), stateVersion: version });
}

function mergePatchEntry(current, next, key) {
  let included = true;
  let value;
  if (!Object.hasOwn(next, key)) {
    value = null;
  } else if (!Object.hasOwn(current, key)) {
    value = canonicalClone(next[key]);
  } else if (jsonEqual(current[key], next[key])) {
    included = false;
  } else {
    value = createMergePatch(current[key], next[key]);
    included = !isJsonObject(value) || Object.keys(value).length > 0;
  }
  return { included, value };
}

/** Build the smallest RFC 7396 patch that transforms current into next. */
export function createMergePatch(current, next) {
  if (jsonEqual(current, next)) return isJsonObject(next) ? {} : canonicalClone(next);
  if (!isJsonObject(current) || !isJsonObject(next)) return canonicalClone(next);
  const patch = {};
  const keys = new Set([...Object.keys(current), ...Object.keys(next)]);
  for (const key of [...keys].sort()) {
    const entry = mergePatchEntry(current, next, key);
    if (entry.included) patch[key] = entry.value;
  }
  return patch;
}
