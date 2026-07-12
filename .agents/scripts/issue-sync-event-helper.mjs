#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { ingestForgeEvent, recordRepositoryForgeEvent } from "./task-coordinator.mjs";

const TARGETED_ACTIONS = new Set(["opened", "edited", "assigned", "closed", "reopened"]);

function option(args, name, fallback = "") {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback;
}
function required(value, label) {
  if (!value) throw new TypeError(`${label} is required`);
  return value;
}
function readJsonFile(path) {
  const canonical = resolve(required(path, "event file"));
  const value = JSON.parse(readFileSync(canonical, "utf8"));
  if (!value || typeof value !== "object") throw new TypeError("event file must contain a JSON object or array");
  return value;
}
function canonicalTimestamp(value, label) {
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) throw new TypeError(`${label} must contain a timestamp`);
  return new Date(value).toISOString();
}
function deterministicDelivery(normalized) {
  return `d${createHash("sha256").update(JSON.stringify(normalized)).digest("hex").slice(0, 40)}`;
}
function assertTrustedRepository(payload, repositoryId, repositorySlug) {
  const eventRepository = payload.repository || {};
  const payloadSlug = eventRepository.full_name;
  const payloadId = eventRepository.node_id || (eventRepository.id === undefined ? "" : String(eventRepository.id));
  if (payloadSlug && payloadSlug !== repositorySlug) throw new Error("event payload repository slug does not match trusted workflow context");
  if (payloadId && payloadId !== repositoryId) throw new Error("event payload repository identity does not match trusted workflow context");
}
function issueProjection(issue, action) {
  return {
    action,
    assignees: Array.isArray(issue.assignees) ? issue.assignees.map((assignee) => String(assignee.login || "")).filter(Boolean).sort() : [],
    state: String(issue.state || "").toLowerCase(),
  };
}
function pullRequestProjection(pullRequest) {
  return {
    action: "merged",
    merged: pullRequest.merged === true || Boolean(pullRequest.merged_at),
    mergeCommitSha: typeof pullRequest.merge_commit_sha === "string" ? pullRequest.merge_commit_sha : "",
    state: String(pullRequest.state || "").toLowerCase(),
  };
}
function normalizeTargetedEvent({ eventName, action, payload, repositoryId, repositorySlug, repositoryPath, deliveryId = "" }) {
  assertTrustedRepository(payload, repositoryId, repositorySlug);
  let eventKind = "";
  let object = null;
  let normalizedAction = action;
  let projection = {};
  let eventCursor = "";
  if (eventName === "issues") {
    if (!TARGETED_ACTIONS.has(action)) throw new TypeError(`unsupported issues action: ${action}`);
    eventKind = "issue";
    object = payload.issue;
    projection = issueProjection(object || {}, action);
    eventCursor = canonicalTimestamp(object?.updated_at, "issue.updated_at");
  } else if (["pull_request", "pull_request_target"].includes(eventName)) {
    object = payload.pull_request;
    if (action !== "closed" || !(object?.merged === true || object?.merged_at)) throw new TypeError("only merged pull request events are targeted");
    eventKind = "pull_request";
    normalizedAction = "merged";
    projection = pullRequestProjection(object);
    eventCursor = canonicalTimestamp(object.merged_at || object.updated_at, "pull_request merge cursor");
  } else {
    throw new TypeError(`unsupported targeted event name: ${eventName}`);
  }
  if (!object || object.number === undefined || (!object.node_id && object.id === undefined)) throw new TypeError("targeted event is missing immutable object identity");
  const normalized = {
    action: normalizedAction,
    eventCursor,
    eventKind,
    objectId: String(object.node_id || object.id),
    objectNumber: Number(object.number),
    projection,
    repositoryId,
    repositoryPath,
    repositorySlug,
  };
  return { ...normalized, deliveryId: deliveryId || deterministicDelivery(normalized) };
}
function ingestEvent(input) {
  const { eventName, action, payload, repositoryId, repositorySlug, repositoryPath, deliveryId = "" } = input;
  if (["issues", "pull_request", "pull_request_target"].includes(eventName)) {
    return ingestForgeEvent(normalizeTargetedEvent(input));
  }
  if (!["push", "workflow_dispatch"].includes(eventName)) throw new TypeError(`unsupported repository event name: ${eventName}`);
  assertTrustedRepository(payload, repositoryId, repositorySlug);
  const eventKind = eventName === "push" ? "push" : "manual";
  const eventCursor = canonicalTimestamp(
    eventName === "push" ? (payload.head_commit?.timestamp || payload.repository?.updated_at) : required(input.eventCursor, "manual event cursor"),
    `${eventKind} event cursor`,
  );
  const projection = eventName === "push" ? { after: String(payload.after || ""), changedPaths: [] } : { command: action || "reconcile" };
  const normalized = { action: action || eventKind, eventCursor, eventKind, projection, repositoryId, repositorySlug };
  return recordRepositoryForgeEvent({ ...normalized, deliveryId: deliveryId || deterministicDelivery(normalized) });
}
function reconcileEvents({ events, maxEvents, trusted }) {
  if (!Array.isArray(events)) throw new TypeError("reconciliation file must contain an event array");
  if (!Number.isSafeInteger(maxEvents) || maxEvents < 1 || maxEvents > 100) throw new TypeError("max-events must be 1..100");
  const selected = events.slice(0, maxEvents).map((entry) => ({
    ...trusted,
    action: required(entry.action, "reconciliation event action"),
    deliveryId: entry.delivery_id || "",
    eventName: required(entry.event_name, "reconciliation event name"),
    payload: required(entry.payload, "reconciliation event payload"),
  }));
  selected.sort((left, right) => {
    const leftObject = left.payload.issue || left.payload.pull_request || left.payload.head_commit || {};
    const rightObject = right.payload.issue || right.payload.pull_request || right.payload.head_commit || {};
    return String(leftObject.updated_at || leftObject.merged_at || leftObject.timestamp || "").localeCompare(String(rightObject.updated_at || rightObject.merged_at || rightObject.timestamp || ""));
  });
  const results = selected.map(ingestEvent);
  return { bounded: true, processed: results.length, results };
}

export function run(args = process.argv.slice(2)) {
  const command = args[0] || "ingest";
  const trusted = {
    repositoryId: required(option(args, "--repository-id"), "repository-id"),
    repositoryPath: required(option(args, "--repository-path"), "repository-path"),
    repositorySlug: required(option(args, "--repository-slug"), "repository-slug"),
  };
  if (command === "ingest") {
    const payload = readJsonFile(option(args, "--event-file"));
    const result = ingestEvent({
      ...trusted,
      action: option(args, "--action"),
      deliveryId: option(args, "--delivery-id"),
      eventCursor: option(args, "--event-cursor"),
      eventName: required(option(args, "--event-name"), "event-name"),
      payload,
    });
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return 0;
  }
  if (command === "reconcile") {
    const result = reconcileEvents({ events: readJsonFile(option(args, "--events-file")), maxEvents: Number(option(args, "--max-events", "50")), trusted });
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return 0;
  }
  throw new TypeError(`unknown issue-sync event command: ${command}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try { process.exitCode = run(); } catch (error) { process.stderr.write(`issue-sync-event: ${error.message}\n`); process.exitCode = 1; }
}

export { ingestEvent, normalizeTargetedEvent, reconcileEvents };
