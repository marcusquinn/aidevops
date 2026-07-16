// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { canonicalTimestamp, isObject } from "./pulse-campaign-values.mjs";

const MAX_HISTORY_ITEMS = 100;
const EVIDENCE_KIND_CHARACTERS = new Set("abcdefghijklmnopqrstuvwxyz0123456789._-");

function validEvidenceKind(value) {
  return typeof value === "string"
    && value.length >= 1
    && value.length <= 64
    && [...value].every((character) => EVIDENCE_KIND_CHARACTERS.has(character));
}

function normalizedCompletedItem(item) {
  if (!isObject(item)) return null;
  const issueNumber = Number(item.issueNumber);
  if (!Number.isSafeInteger(issueNumber) || issueNumber < 1) return null;
  const kind = validEvidenceKind(item.kind) ? item.kind : "verified-terminal-evidence";
  const observedAt = canonicalTimestamp(item.observedAt, "");
  return { issueNumber, kind, ...(observedAt ? { observedAt } : {}) };
}

export function normalizeCompletedEvidence(value) {
  if (!Array.isArray(value)) return [];
  const seen = new Set();
  const result = [];
  for (const item of value) {
    const normalized = normalizedCompletedItem(item);
    if (!normalized) continue;
    const key = `${normalized.issueNumber}:${normalized.kind}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(normalized);
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
