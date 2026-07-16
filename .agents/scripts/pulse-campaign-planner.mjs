// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { normalizeCompletedEvidence, normalizeDiscoveries } from "./pulse-campaign-history.mjs";
import {
  blockReasons,
  isActive,
  isBlocked,
  issueReference,
  normalizeIssueList,
  oldestIssueOrder,
} from "./pulse-campaign-issues.mjs";
import { allocateLanes, mergeRunners } from "./pulse-campaign-runners.mjs";
import { canonicalTimestamp, clampInteger, hash, isObject } from "./pulse-campaign-values.mjs";

export const CAMPAIGN_SCHEMA_VERSION = 1;
export const DEFAULT_HORIZON = 10;
export const DEFAULT_CHECKPOINT_TTL_SECONDS = 3600;
export const REPOSITORY_SLUG = /^[^/\s]+\/[^/\s]+$/;

export function validPreviousCheckpoint(previous, campaignId, scopeKey) {
  if (!isObject(previous)) return false;
  if (previous.schemaVersion !== CAMPAIGN_SCHEMA_VERSION) return false;
  if (previous.kind !== "aidevops.repository-campaign") return false;
  if (previous.campaignId !== campaignId) return false;
  return previous.repository?.scopeKey === scopeKey;
}

function validatedRepositorySlug(value) {
  if (typeof value !== "string" || !REPOSITORY_SLUG.test(value)) throw new TypeError("repository slug is invalid");
  return value;
}

function validatedScopeKey(value) {
  if (typeof value !== "string" || !/^[0-9a-f]{16}$/.test(value)) throw new TypeError("repository scope key is invalid");
  return value;
}

function validatedCampaignTimestamp(value) {
  const timestamp = canonicalTimestamp(value ?? new Date().toISOString());
  if (!timestamp) throw new TypeError("campaign timestamp is invalid");
  return timestamp;
}

function campaignContext(input) {
  if (!isObject(input)) throw new TypeError("campaign input must be an object");
  const repositorySlug = validatedRepositorySlug(input.repositorySlug);
  const scopeKey = validatedScopeKey(input.scopeKey);
  const now = validatedCampaignTimestamp(input.now);
  return {
    campaignId: `campaign-${hash(scopeKey, 20)}`,
    horizon: clampInteger(input.horizon, 1, 100, DEFAULT_HORIZON),
    now,
    repositorySlug,
    scopeKey,
    sourceLimit: clampInteger(input.sourceLimit, 1, 100000, 1000),
    ttlSeconds: clampInteger(input.ttlSeconds, 60, 86400, DEFAULT_CHECKPOINT_TTL_SECONDS),
  };
}

function sourceSnapshotSucceeded(input, normalizedSource) {
  return [
    input.sourceSucceeded !== false,
    normalizedSource.validContainer,
    normalizedSource.invalidCount === 0,
  ].every(Boolean);
}

function sourceSnapshotComplete(input, succeeded, normalizedSource, sourceLimit) {
  if (!succeeded) return false;
  if (typeof input.sourceComplete === "boolean") return input.sourceComplete;
  return normalizedSource.rawCount < sourceLimit;
}

function campaignSourceState(input, sourceLimit) {
  const normalizedSource = normalizeIssueList(input.issues);
  const issues = normalizedSource.issues;
  const succeeded = sourceSnapshotSucceeded(input, normalizedSource);
  const readyNumbers = new Set(normalizeIssueList(input.readyIssues).issues.map((issue) => issue.issueNumber));
  const ready = succeeded
    ? issues.filter((issue) => readyNumbers.has(issue.issueNumber)).sort(oldestIssueOrder)
    : [];
  const complete = sourceSnapshotComplete(input, succeeded, normalizedSource, sourceLimit);
  const projectedIssues = succeeded ? issues : [];
  const currentNumbers = new Set(projectedIssues.map((issue) => issue.issueNumber));
  return { complete, currentNumbers, issues, projectedIssues, ready, succeeded };
}

function previousIssueNumbers(previous) {
  const issueNumbers = Array.isArray(previous?.knownIssueNumbers)
    ? previous.knownIssueNumbers.filter(Number.isSafeInteger)
    : [];
  return new Set(issueNumbers);
}

function campaignHistory(previous, input, source, previousKnown, now) {
  const completedEvidence = normalizeCompletedEvidence([
    ...(previous?.completedEvidence ?? []),
    ...(input.completedEvidence ?? []),
    ...(source.complete
      ? [...previousKnown]
        .filter((issueNumber) => !source.currentNumbers.has(issueNumber))
        .map((issueNumber) => ({ issueNumber, kind: "left-open-snapshot", observedAt: now }))
      : []),
  ]);
  const discoveries = normalizeDiscoveries([
    ...(previous?.discoveries ?? []),
    ...source.projectedIssues
      .filter((issue) => !previousKnown.has(issue.issueNumber))
      .map((issue) => ({ issueNumber: issue.issueNumber, firstSeenAt: now })),
  ]);
  return { completedEvidence, discoveries };
}

function knownIssueNumbers(source, previousKnown) {
  if (source.complete) return source.currentNumbers;
  if (source.succeeded) return new Set([...previousKnown, ...source.currentNumbers]);
  return previousKnown;
}

function campaignCategories(source, horizon) {
  const frontier = source.ready.slice(0, horizon)
    .map((issue, index) => ({ ...issueReference(issue), position: index + 1 }));
  const remaining = source.ready.slice(horizon).map(issueReference);
  const active = source.projectedIssues
    .filter((issue) => !isBlocked(issue) && isActive(issue))
    .sort(oldestIssueOrder)
    .map(issueReference);
  const blocked = source.projectedIssues
    .filter(isBlocked)
    .sort(oldestIssueOrder)
    .map((issue) => ({ ...issueReference(issue), reasons: blockReasons(issue) }));
  return { active, blocked, frontier, remaining };
}

function campaignTiming(now, ttlSeconds) {
  const generatedEpoch = Date.parse(now);
  return {
    expiresAt: new Date(generatedEpoch + ttlSeconds * 1000).toISOString(),
    renewAfter: new Date(generatedEpoch + Math.floor(ttlSeconds / 2) * 1000).toISOString(),
  };
}

function campaignSourceProjection(input, source, sourceLimit, generatedAt) {
  const observedAt = canonicalTimestamp(input.sourceObservedAt, generatedAt);
  return {
    openIssueCount: source.issues.length,
    readyIssueCount: source.ready.length,
    limit: sourceLimit,
    succeeded: source.succeeded,
    complete: source.complete,
    observedAt,
    hash: `sha256:${hash({
      issues: source.issues,
      ready: source.ready.map((issue) => issue.issueNumber),
    })}`,
  };
}

export function planCampaign(input, previousCheckpoint = null) {
  const context = campaignContext(input);
  const previous = validPreviousCheckpoint(previousCheckpoint, context.campaignId, context.scopeKey)
    ? previousCheckpoint
    : null;
  const sourceState = campaignSourceState(input, context.sourceLimit);
  const previousKnown = previousIssueNumbers(previous);
  const history = campaignHistory(previous, input, sourceState, previousKnown, context.now);
  const categories = campaignCategories(sourceState, context.horizon);
  const runners = mergeRunners(Array.isArray(input.runners) ? input.runners : [], context.repositorySlug);
  const timing = campaignTiming(context.now, context.ttlSeconds);
  const source = campaignSourceProjection(input, sourceState, context.sourceLimit, context.now);
  return {
    schemaVersion: CAMPAIGN_SCHEMA_VERSION,
    kind: "aidevops.repository-campaign",
    campaignId: context.campaignId,
    generation: clampInteger(previous?.generation, 0, Number.MAX_SAFE_INTEGER - 1, 0) + 1,
    generatedAt: context.now,
    renewAfter: timing.renewAfter,
    expiresAt: timing.expiresAt,
    horizon: context.horizon,
    mode: "shadow",
    canonicalAuthority: "github+git",
    fallback: "legacy-deterministic-dispatch",
    repository: { slug: context.repositorySlug, scopeKey: context.scopeKey },
    source,
    frontier: categories.frontier,
    completedEvidence: history.completedEvidence,
    discoveries: history.discoveries,
    active: categories.active,
    blocked: categories.blocked,
    remaining: categories.remaining,
    knownIssueNumbers: [...knownIssueNumbers(sourceState, previousKnown)]
      .sort((left, right) => left - right),
    runners,
    lanes: allocateLanes(categories.frontier, runners, context.campaignId),
  };
}
