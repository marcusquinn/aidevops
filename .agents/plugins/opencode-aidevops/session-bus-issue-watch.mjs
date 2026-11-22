// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t19157/GH#39240: issue watches. A root interactive session watches an issue
// or PR (owner/repo#N) for 7 days; the 2-minute pulse relay
// (worker-bus-relay-watches.sh) diffs GitHub state and sends the watcher one
// batched `info` pointer per pass. issue-watch/<sessionID>/<owner>@<repo>@<n>.json
// holds one watch; the relay keeps its own detection state elsewhere.
//
// #aidevops:trust-boundary Watches are advisory. Notices are pointers (numbers,
// labels, logins, comment IDs) that the watcher verifies on GitHub; they never
// grant authority, and nothing reads a watch back for a decision.
// Docs: reference/session-bus.md "Issue watches".

import { rmSync } from "node:fs";
import { join } from "node:path";

import {
  BUS_VERSION,
  LIMITS,
  isSafeId,
  issueWatchDir,
  listDir,
  presenceDir,
  pruneTemp,
  readJson,
  writeJsonAtomic,
} from "./session-bus-files.mjs";
import { isMessageable } from "./session-bus-presence-store.mjs";

export const ISSUE_WATCH_LIMITS = Object.freeze({ perSession: 50 });

const SLUG = /^([A-Za-z0-9_.-]{1,100})\/([A-Za-z0-9_.-]{1,100})$/;
const NUMBER = /^[1-9]\d{0,9}$/;
const WATCH_FILE = /^[a-z0-9_.-]+@[a-z0-9_.-]+@[1-9]\d{0,9}\.json$/;

/**
 * `owner/repo#N`, or `#N` / `N` with `defaultRepo`. Returns { repo, number, key }.
 * GitHub names are case-insensitive, so the key is lower case.
 */
export function parseIssueRef(ref, defaultRepo = "") {
  const text = String(ref || "").trim();
  const hash = text.lastIndexOf("#");
  const repo = (hash > 0 ? text.slice(0, hash) : String(defaultRepo || "")).trim();
  const number = (hash >= 0 ? text.slice(hash + 1) : text).trim();
  const slug = SLUG.exec(repo);
  if (!slug || /^\.+$/.test(slug[1]) || /^\.+$/.test(slug[2])) {
    throw new Error("issue must look like owner/repo#N (or #N inside a session on that repo)");
  }
  if (!NUMBER.test(number)) throw new Error("issue number must be a positive whole number");
  return { repo, number: Number(number), key: `${slug[1]}@${slug[2]}@${number}`.toLowerCase() };
}

const watchFile = (root, sessionID, key) => join(issueWatchDir(root, sessionID), `${key}.json`);
const hasPresence = (root, sessionID) => readJson(join(presenceDir(root), `${sessionID}.json`)) !== null;

function assertWatcher(record) {
  if (!record || !isSafeId(record.session_id)) throw new Error("watch-issue needs the caller's live session");
  if (!isMessageable(record) || record.kind === "headless") {
    throw new Error(`${record.handle || record.session_id} is a ${record.kind || "read-only"} session; issue watches are for interactive sessions (workers read their issue on GitHub)`);
  }
}

/**
 * Watch one issue or PR for 7 days. `fresh` marks an item the caller just
 * created, so the relay's first pass reports state that changed before it ran
 * (a fast worker pickup) instead of taking it as the baseline.
 */
export function addIssueWatch(root, ref, record, { fresh = false, now = Date.now() } = {}) {
  assertWatcher(record);
  const item = parseIssueRef(ref, record.repo);
  const file = watchFile(root, record.session_id, item.key);
  // An expired or malformed record not yet pruned is a new watch: new start, cap applies.
  const found = readJson(file);
  const existing = liveWatch(found, record.session_id, `${item.key}.json`, now) ? found : null;
  if (!existing && sessionIssueWatches(root, record.session_id, now).length >= ISSUE_WATCH_LIMITS.perSession) {
    throw new Error(`at most ${ISSUE_WATCH_LIMITS.perSession} issue watches per session; stop one with --off first`);
  }
  const watch = {
    v: BUS_VERSION,
    repo: item.repo,
    number: item.number,
    key: item.key,
    subscriber: record.session_id,
    handle: String(record.handle || "").slice(0, 80),
    created_ms: existing?.created_ms ?? now,
    expires_ms: now + LIMITS.retentionMs,
    fresh: Boolean(existing?.fresh || fresh),
  };
  writeJsonAtomic(file, watch);
  return watch;
}

export function removeIssueWatch(root, ref, sessionID, defaultRepo = "") {
  if (!isSafeId(sessionID)) return false;
  const file = watchFile(root, sessionID, parseIssueRef(ref, defaultRepo).key);
  const existed = readJson(file) !== null;
  rmSync(file, { force: true });
  return existed;
}

function validWatch(record, sessionID, name) {
  if (record?.v !== BUS_VERSION || record.subscriber !== sessionID) return false;
  if (name !== `${record.key}.json` || !SLUG.test(String(record.repo || ""))) return false;
  return Number.isSafeInteger(record.number) && record.number > 0;
}

const liveWatch = (record, sessionID, name, now) => validWatch(record, sessionID, name) && record.expires_ms > now;

/** One session's live watches; expired or malformed records are removed. */
export function sessionIssueWatches(root, sessionID, now = Date.now()) {
  if (!isSafeId(sessionID)) return [];
  const dir = issueWatchDir(root, sessionID);
  const watches = [];
  for (const name of listDir(dir).filter((file) => WATCH_FILE.test(file))) {
    const record = readJson(join(dir, name));
    if (liveWatch(record, sessionID, name, now)) watches.push(record);
    else rmSync(join(dir, name), { force: true });
  }
  return watches.sort((left, right) => left.created_ms - right.created_ms);
}

/** Every live watch, for the relay. Watches of sessions without presence are removed. */
export function allIssueWatches(root, now = Date.now()) {
  const watches = [];
  for (const sessionID of listDir(join(root, "issue-watch"))) {
    if (!isSafeId(sessionID) || !hasPresence(root, sessionID)) {
      rmSync(issueWatchDir(root, sessionID), { recursive: true, force: true });
      continue;
    }
    watches.push(...sessionIssueWatches(root, sessionID, now));
  }
  return watches;
}

/**
 * Retention, composed by pruneBus in session-bus-store.mjs: a watch ends when
 * it expires (7 days) or its session has no presence; stale temp files and
 * empty session directories go too.
 */
export function pruneIssueWatches(root, now = Date.now()) {
  allIssueWatches(root, now);
  for (const sessionID of listDir(join(root, "issue-watch"))) {
    const dir = issueWatchDir(root, sessionID);
    for (const name of listDir(dir).filter((file) => file.endsWith(".tmp"))) pruneTemp(join(dir, name));
    if (listDir(dir).length === 0) rmSync(dir, { recursive: true, force: true });
  }
}
