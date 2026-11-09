// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: resolve a session-bus `to` argument (session ID, handle,
// #issue, PR#n, worktree, repo or title words) to one live presence record.
// t18895: matchSessions returns every live record on a target, for `who`.

import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";

import { isSafeId } from "./session-bus-files.mjs";

const SELF_TARGET = "that target is this session; messages to yourself are rejected";

function expandHome(path) {
  const text = String(path || "");
  return text.startsWith("~/") ? join(homedir(), text.slice(2)) : text;
}

const sameText = (left, right) => String(left || "").toLowerCase() === String(right || "").toLowerCase();

function matchesNumber(pattern, query, value) {
  const match = pattern.exec(query);
  return Boolean(match) && value === Number(match[1]);
}

function matchesWorktree(record, query) {
  const path = expandHome(query).replace(/\/+$/, "");
  return Boolean(path) && (record.worktree === path || basename(String(record.worktree || "")) === path);
}

const repoName = (record) => String(record.repo || "").split("/").pop();

// Exact tiers first; the first tier with any match wins. Several matches in
// that tier are ambiguous: the caller gets the candidates, never a guess.
const TARGET_TIERS = [
  (record, query) => record.session_id === query,
  (record, query) => sameText(record.handle, query),
  (record, query) => matchesNumber(/^(?:issue\s*|gh)?#(\d+)$/i, query, record.issue),
  (record, query) => matchesNumber(/^pr\s*#?(\d+)$/i, query, record.pr),
  matchesWorktree,
  (record, query) => sameText(record.repo, query) || sameText(repoName(record), query),
  (record, query) => query.length >= 4 && String(record.title || "").toLowerCase().includes(query.toLowerCase()),
];

function tierResult(found, query, selfID) {
  const others = found.filter((record) => record.session_id !== selfID);
  if (others.length === 0) return { error: SELF_TARGET };
  if (others.length === 1) return { record: others[0] };
  return { error: `target "${query}" matches ${others.length} sessions; use a handle or session ID`, candidates: others };
}

// A session ID with no live record is still addressable: the message waits
// in its inbox until that session resumes.
function offlineResult(query, selfID) {
  if (!isSafeId(query) || !query.startsWith("ses_")) {
    return { error: `no live OpenCode session matches "${query}"; run list to see sessions` };
  }
  if (query === selfID) return { error: SELF_TARGET };
  return { record: null, sessionID: query, offline: true };
}

export function resolveTarget(records, to, selfID = "") {
  const query = String(to || "").trim();
  if (!query) return { error: "missing target: pass `to` (session ID, handle, #issue, PR#n, repo or worktree)" };
  for (const matches of TARGET_TIERS) {
    const found = records.filter((record) => matches(record, query));
    if (found.length > 0) return tierResult(found, query, selfID);
  }
  return offlineResult(query, selfID);
}

// ---------------------------------------------------------------------------
// t18895: every live session on a target, for `who`, pre-work and claim checks
// ---------------------------------------------------------------------------

const looksLikePath = (query) => /^[./~]/.test(query) || query.includes("/");

function normalizePath(query, cwd) {
  return resolve(cwd || process.cwd(), expandHome(query)).replace(/\/+$/, "") || "/";
}

/** A path is inside a session's Git worktree (never its bare directory, which may be a parent like ~/Git). */
function worktreeContains(record, path) {
  const root = String(record.worktree || "").replace(/\/+$/, "");
  return Boolean(root) && (path === root || path.startsWith(`${root}/`));
}

function whoPredicate(query, cwd) {
  const checks = [
    (record) => record.session_id === query || sameText(record.handle, query),
    (record) => sameText(record.repo, query) || sameText(repoName(record), query),
  ];
  const issue = /^(?:issue\s*|gh)?#(\d+)$/i.exec(query);
  if (issue) checks.push((record) => record.issue === Number(issue[1]));
  const pr = /^pr\s*#?(\d+)$/i.exec(query);
  if (pr) checks.push((record) => record.pr === Number(pr[1]));
  if (looksLikePath(query)) {
    const path = normalizePath(query, cwd);
    checks.push((record) => worktreeContains(record, path));
  }
  return (record) => checks.some((check) => check(record));
}

/**
 * Every live record working on `target` (#issue, PR#n, repo slug or name,
 * handle, session ID, worktree or file path), excluding the caller. Unlike
 * resolveTarget this never picks one: callers show all of them.
 * @param {object} options - { selfID, cwd (resolves relative paths), repo (only this repo) }
 */
export function matchSessions(records, target, { selfID = "", cwd = "", repo = "" } = {}) {
  const query = String(target || "").trim();
  if (!query) throw new Error("missing target: #issue, PR#n, repo, worktree or file path");
  const matches = whoPredicate(query, cwd);
  const inScope = (record) => !repo || sameText(record.repo, repo);
  return records.filter((record) => record.session_id !== selfID && inScope(record) && matches(record));
}

/** matchSessions for several targets: each live record once. */
export function matchAnySessions(records, targets, options = {}) {
  if (targets.length === 0) throw new Error("who needs a target: #issue, PR#n, repo, worktree or file path");
  const found = new Map();
  for (const target of targets) {
    for (const record of matchSessions(records, target, options)) found.set(record.session_id, record);
  }
  return [...found.values()];
}
