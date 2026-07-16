// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { canonicalTimestamp, isObject } from "./pulse-campaign-values.mjs";

const MAX_HISTORY_ITEMS = 100;

export function normalizeCompletedEvidence(value) {
  if (!Array.isArray(value)) return [];
  const seen = new Set();
  const result = [];
  for (const item of value) {
    if (!isObject(item)) continue;
    const issueNumber = Number(item.issueNumber);
    if (!Number.isSafeInteger(issueNumber) || issueNumber < 1) continue;
    const kind = typeof item.kind === "string" && /^[a-z0-9._-]{1,64}$/.test(item.kind)
      ? item.kind
      : "verified-terminal-evidence";
    const observedAt = canonicalTimestamp(item.observedAt, "");
    const key = `${issueNumber}:${kind}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push({ issueNumber, kind, ...(observedAt ? { observedAt } : {}) });
  }
  return result.slice(-MAX_HISTORY_ITEMS);
}

export function normalizeDiscoveries(value) {
  if (!Array.isArray(value)) return [];
  const byIssue = new Map();
  for (const item of value) {
    if (!isObject(item)) continue;
    const issueNumber = Number(item.issueNumber);
    if (!Number.isSafeInteger(issueNumber)) continue;
    if (issueNumber < 1) continue;
    if (byIssue.has(issueNumber)) continue;
    const firstSeenAt = canonicalTimestamp(item.firstSeenAt, "");
    byIssue.set(issueNumber, {
      issueNumber,
      source: "github-open-snapshot",
      ...(firstSeenAt ? { firstSeenAt } : {}),
    });
  }
  return [...byIssue.values()].slice(-MAX_HISTORY_ITEMS);
}
