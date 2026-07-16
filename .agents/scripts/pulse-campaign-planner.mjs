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

export function planCampaign(input, previousCheckpoint = null) {
  if (!isObject(input)) throw new TypeError("campaign input must be an object");
  const repositorySlug = input.repositorySlug;
  const scopeKey = input.scopeKey;
  if (typeof repositorySlug !== "string" || !REPOSITORY_SLUG.test(repositorySlug)) throw new TypeError("repository slug is invalid");
  if (typeof scopeKey !== "string" || !/^[0-9a-f]{16}$/.test(scopeKey)) throw new TypeError("repository scope key is invalid");
  const now = canonicalTimestamp(input.now ?? new Date().toISOString());
  if (!now) throw new TypeError("campaign timestamp is invalid");
  const horizon = clampInteger(input.horizon, 1, 100, DEFAULT_HORIZON);
  const ttlSeconds = clampInteger(input.ttlSeconds, 60, 86400, DEFAULT_CHECKPOINT_TTL_SECONDS);
  const sourceLimit = clampInteger(input.sourceLimit, 1, 100000, 1000);
  const normalizedSource = normalizeIssueList(input.issues);
  const issues = normalizedSource.issues;
  const campaignId = `campaign-${hash(scopeKey, 20)}`;
  const previous = validPreviousCheckpoint(previousCheckpoint, campaignId, scopeKey) ? previousCheckpoint : null;
  const sourceSucceeded = input.sourceSucceeded !== false && normalizedSource.validContainer && normalizedSource.invalidCount === 0;
  const readyNumbers = new Set(normalizeIssueList(input.readyIssues).issues.map((issue) => issue.issueNumber));
  const ready = sourceSucceeded
    ? issues.filter((issue) => readyNumbers.has(issue.issueNumber)).sort(oldestIssueOrder)
    : [];
  const sourceComplete = typeof input.sourceComplete === "boolean"
    ? input.sourceComplete && sourceSucceeded
    : sourceSucceeded && normalizedSource.rawCount < sourceLimit;
  const projectedIssues = sourceSucceeded ? issues : [];
  const currentNumbers = new Set(projectedIssues.map((issue) => issue.issueNumber));
  const previousKnown = new Set(Array.isArray(previous?.knownIssueNumbers) ? previous.knownIssueNumbers.filter(Number.isSafeInteger) : []);
  const completedEvidence = normalizeCompletedEvidence([
    ...(previous?.completedEvidence ?? []),
    ...(input.completedEvidence ?? []),
    ...(sourceComplete
      ? [...previousKnown]
        .filter((issueNumber) => !currentNumbers.has(issueNumber))
        .map((issueNumber) => ({ issueNumber, kind: "left-open-snapshot", observedAt: now }))
      : []),
  ]);
  const discoveries = normalizeDiscoveries([
    ...(previous?.discoveries ?? []),
    ...projectedIssues
      .filter((issue) => !previousKnown.has(issue.issueNumber))
      .map((issue) => ({ issueNumber: issue.issueNumber, firstSeenAt: now })),
  ]);
  const frontier = ready.slice(0, horizon).map((issue, index) => ({ ...issueReference(issue), position: index + 1 }));
  const remaining = ready.slice(horizon).map(issueReference);
  const active = projectedIssues.filter((issue) => !isBlocked(issue) && isActive(issue)).sort(oldestIssueOrder).map(issueReference);
  const blocked = projectedIssues.filter(isBlocked).sort(oldestIssueOrder).map((issue) => ({ ...issueReference(issue), reasons: blockReasons(issue) }));
  const runners = mergeRunners(Array.isArray(input.runners) ? input.runners : [], repositorySlug);
  const generatedAt = now;
  const sourceObservedAt = canonicalTimestamp(input.sourceObservedAt, generatedAt);
  const generatedEpoch = Date.parse(generatedAt);
  const renewAfter = new Date(generatedEpoch + Math.floor(ttlSeconds / 2) * 1000).toISOString();
  const expiresAt = new Date(generatedEpoch + ttlSeconds * 1000).toISOString();
  const sourceProjection = {
    openIssueCount: issues.length,
    readyIssueCount: ready.length,
    limit: sourceLimit,
    succeeded: sourceSucceeded,
    complete: sourceComplete,
    observedAt: sourceObservedAt,
    hash: `sha256:${hash({ issues, ready: ready.map((issue) => issue.issueNumber) })}`,
  };
  return {
    schemaVersion: CAMPAIGN_SCHEMA_VERSION,
    kind: "aidevops.repository-campaign",
    campaignId,
    generation: clampInteger(previous?.generation, 0, Number.MAX_SAFE_INTEGER - 1, 0) + 1,
    generatedAt,
    renewAfter,
    expiresAt,
    horizon,
    mode: "shadow",
    canonicalAuthority: "github+git",
    fallback: "legacy-deterministic-dispatch",
    repository: { slug: repositorySlug, scopeKey },
    source: sourceProjection,
    frontier,
    completedEvidence,
    discoveries,
    active,
    blocked,
    remaining,
    knownIssueNumbers: [...(sourceComplete
      ? currentNumbers
      : sourceSucceeded
        ? new Set([...previousKnown, ...currentNumbers])
        : previousKnown)].sort((left, right) => left - right),
    runners,
    lanes: allocateLanes(frontier, runners, campaignId),
  };
}
