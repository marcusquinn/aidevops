// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { LOGIN } from "./pulse-campaign-runners.mjs";
import { canonicalTimestamp, compareAscii, isObject } from "./pulse-campaign-values.mjs";

function normalizedLabels(issue) {
  if (!Array.isArray(issue?.labels)) return [];
  return [...new Set(issue.labels
    .map((label) => typeof label === "string" ? label : label?.name)
    .filter((label) => typeof label === "string" && label.length > 0 && label.length <= 100))]
    .sort();
}

function normalizedAssignees(issue) {
  if (!Array.isArray(issue?.assignees)) return [];
  return [...new Set(issue.assignees
    .map((assignee) => typeof assignee === "string" ? assignee : assignee?.login)
    .filter((login) => typeof login === "string" && LOGIN.test(login)))]
    .sort(compareAscii);
}

function normalizeIssue(issue) {
  if (!isObject(issue)) return null;
  const issueNumber = Number(issue.number ?? issue.issueNumber);
  if (!Number.isSafeInteger(issueNumber) || issueNumber < 1) return null;
  return {
    issueNumber,
    createdAt: canonicalTimestamp(issue.createdAt, "9999-12-31T23:59:59.999Z"),
    updatedAt: canonicalTimestamp(issue.updatedAt, ""),
    labels: normalizedLabels(issue),
    assignees: normalizedAssignees(issue),
  };
}

function validLabel(label) {
  const name = typeof label === "string" ? label : label?.name;
  return typeof name === "string" && name.length > 0 && name.length <= 100;
}

function validAssignee(assignee) {
  const login = typeof assignee === "string" ? assignee : assignee?.login;
  return typeof login === "string" && LOGIN.test(login);
}

function issueInputIsLossless(issue) {
  if (!isObject(issue)) return false;
  if (!Array.isArray(issue.labels)) return false;
  if (!Array.isArray(issue.assignees)) return false;
  return issue.labels.every(validLabel) && issue.assignees.every(validAssignee);
}

export function normalizeIssueList(value) {
  const validContainer = Array.isArray(value);
  const rawIssues = validContainer ? value : [];
  const normalized = [];
  let invalidCount = 0;
  for (const rawIssue of rawIssues) {
    const issue = normalizeIssue(rawIssue);
    if (!issue || !issueInputIsLossless(rawIssue)) invalidCount += 1;
    if (issue) normalized.push(issue);
  }
  const byIssue = new Map();
  for (const issue of normalized) {
    if (!byIssue.has(issue.issueNumber)) byIssue.set(issue.issueNumber, issue);
  }
  invalidCount += normalized.length - byIssue.size;
  return {
    issues: [...byIssue.values()],
    rawCount: rawIssues.length,
    invalidCount,
    validContainer,
  };
}

export function issueReference(issue) {
  return {
    issueNumber: issue.issueNumber,
    createdAt: issue.createdAt,
    ...(issue.updatedAt ? { updatedAt: issue.updatedAt } : {}),
  };
}

export function oldestIssueOrder(left, right) {
  return compareAscii(left.createdAt, right.createdAt) || left.issueNumber - right.issueNumber;
}

export function isBlocked(issue) {
  return issue.labels.includes("status:blocked") || issue.labels.some((label) => label.startsWith("needs-"));
}

export function isActive(issue) {
  return issue.assignees.length > 0 || ["status:claimed", "status:in-progress", "status:in-review"]
    .some((label) => issue.labels.includes(label));
}

export function blockReasons(issue) {
  const reasons = [];
  if (issue.labels.includes("status:blocked")) reasons.push("status:blocked");
  if (issue.labels.some((label) => label.startsWith("needs-"))) reasons.push("needs-gate");
  return reasons;
}
