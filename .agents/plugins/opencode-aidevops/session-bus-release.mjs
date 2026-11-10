// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18896/GH#37249: release-lane watches and notices over the session bus.
// release-watch/<repoKey>/<sessionID>.json holds one watch per root session.
// It is separate from subs/<sessionID>/ (notify-when-idle), which is keyed by
// the watched session. A notice is an `info` message from a sessionless `cli`
// sender, so it never wakes an idle session.
//
// #aidevops:trust-boundary Watches and notices are advisory. They never grant
// release, reconcile, recovery or publication authority, and the release lane
// never reads them back. Docs: reference/session-bus.md "Release notices".

import { createHash } from "node:crypto";
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import {
  BUS_VERSION,
  LIMITS,
  ensureDir,
  isSafeId,
  listDir,
  presenceDir,
  readJson,
  releaseNoticeDir,
  releaseWatchDir,
  writeJsonAtomic,
} from "./session-bus-files.mjs";
import { sendReleaseNotice } from "./session-bus-messages.mjs";

export const RELEASE_EVENTS = Object.freeze(["published", "superseded", "failed", "executor-dead"]);

const REPO_SLUG = /^([A-Za-z0-9_.-]{1,100})\/([A-Za-z0-9_.-]{1,100})$/;
const SOURCE_PR = /^[1-9]\d{0,9}$/;
const TAG = /^v\d{1,6}\.\d{1,6}\.\d{1,6}$/;
const WORD = /^[a-z0-9][a-z0-9-]{0,39}$/;
const RECOVERY = /^aidevops release (?:status|reconcile|recover-reservation) [1-9]\d{0,9}$/;
/** Directory key for an owner/repo slug; GitHub names are case-insensitive. */
export function releaseRepoKey(repo) {
  const match = REPO_SLUG.exec(String(repo || "").trim());
  if (!match || /^\.+$/.test(match[1]) || /^\.+$/.test(match[2])) throw new Error("repo must look like owner/repo");
  return `${match[1]}@${match[2]}`.toLowerCase();
}

const watchFile = (root, repo, sessionID) => join(releaseWatchDir(root, releaseRepoKey(repo)), `${sessionID}.json`);
const hasPresence = (root, sessionID) => readJson(join(presenceDir(root), `${sessionID}.json`)) !== null;

/** Subscribe one root session to a repository's release notices for 7 days. */
export function addReleaseWatch(root, repo, subscriber, now = Date.now()) {
  if (!isSafeId(subscriber?.session_id)) throw new Error("watch-release needs the caller's session ID");
  const record = {
    v: BUS_VERSION,
    repo: String(repo).trim(),
    subscriber: subscriber.session_id,
    handle: String(subscriber.handle || "").slice(0, 80),
    created_ms: now,
    expires_ms: now + LIMITS.retentionMs,
  };
  writeJsonAtomic(watchFile(root, repo, subscriber.session_id), record);
  return record;
}

export function removeReleaseWatch(root, repo, sessionID) {
  if (!isSafeId(sessionID)) return false;
  const file = watchFile(root, repo, sessionID);
  const existed = readJson(file) !== null;
  rmSync(file, { force: true });
  return existed;
}

/** Live watches for a repository; expired or presence-less watches are removed. */
export function releaseWatchers(root, repo, now = Date.now()) {
  const dir = releaseWatchDir(root, releaseRepoKey(repo));
  const watchers = [];
  for (const name of listDir(dir).filter((file) => file.endsWith(".json"))) {
    const record = readJson(join(dir, name));
    const valid = record?.v === BUS_VERSION && isSafeId(record.subscriber) && name === `${record.subscriber}.json`;
    if (valid && record.expires_ms > now && hasPresence(root, record.subscriber)) watchers.push(record);
    else rmSync(join(dir, name), { force: true });
  }
  return watchers;
}

const optional = (value, pattern, label) => {
  const text = String(value ?? "").trim();
  if (text && !pattern.test(text)) throw new Error(`invalid ${label}`);
  return text;
};

function validNotice(options) {
  const event = String(options?.event || "");
  if (!RELEASE_EVENTS.includes(event)) throw new Error(`--event must be one of: ${RELEASE_EVENTS.join(", ")}`);
  const sourcePr = String(options?.sourcePr ?? "").trim();
  if (!SOURCE_PR.test(sourcePr)) throw new Error("--source-pr must be a PR number");
  releaseRepoKey(options?.repo);
  return {
    repo: String(options.repo).trim(),
    sourcePr,
    event,
    tag: optional(options.tag, TAG, "--tag"),
    receipt: optional(options.receipt, WORD, "--receipt"),
    executorState: optional(options.executorState, WORD, "--executor-state"),
    recovery: optional(options.recovery, RECOVERY, "--recovery"),
    ownerSession: isSafeId(options.ownerSession) ? options.ownerSession : "",
    marker: String(options.marker || "").slice(0, 512),
  };
}

const EVENT_TEXT = {
  published: (notice) => `published ${notice.tag || "its release"}`,
  superseded: (notice) => `was superseded${notice.tag ? ` at ${notice.tag}` : ""}`,
  failed: (notice) => `finalized as ${notice.receipt || "failed"}${notice.tag ? ` at ${notice.tag}` : ""}`,
  "executor-dead": (notice) => `has a dead release executor (${notice.executorState || "dead"}, tag ${notice.tag || "pending"})`,
};

export function releaseNoticeText(notice) {
  const lines = [`Release lane ${notice.repo} PR #${notice.sourcePr} ${EVENT_TEXT[notice.event](notice)}.`];
  if (notice.receipt) lines.push(`Receipt: ${notice.receipt}.`);
  if (notice.recovery) lines.push(`Recovery command: ${notice.recovery}`);
  else if (notice.event !== "published") lines.push(`Inspect with: aidevops release status ${notice.sourcePr}`);
  lines.push("Advisory only: this notice does not authorise a release, recovery or publication.");
  return lines.join("\n");
}

// Exclusive create, so concurrent observers send a marked notice once.
function claimNoticeMarker(root, repoKey, notice, now) {
  const digest = createHash("sha256").update(`${notice.event}\n${notice.sourcePr}\n${notice.marker}`).digest("hex");
  const dir = releaseNoticeDir(root, repoKey);
  ensureDir(dir);
  const record = { v: BUS_VERSION, repo: notice.repo, source_pr: Number(notice.sourcePr), event: notice.event, created_ms: now };
  if (notice.event === "executor-dead") record.notified_dead_at = new Date(now).toISOString();
  try {
    writeFileSync(join(dir, `${digest.slice(0, 40)}.json`), `${JSON.stringify(record)}\n`, { flag: "wx", mode: 0o600 });
    return true;
  } catch (error) {
    if (error?.code === "EEXIST") return false;
    throw error;
  }
}

/**
 * Send one `info` notice to every live watcher of the repository and to the
 * lane owner session. A notice with a marker is sent at most once; the marker
 * is only claimed when someone would receive it. Per-recipient failures are
 * reported, never thrown, so one full inbox cannot block the others.
 */
export function notifyRelease(root, options, now = Date.now()) {
  const notice = validNotice(options);
  const repoKey = releaseRepoKey(notice.repo);
  const recipients = new Map(releaseWatchers(root, notice.repo, now).map((watch) => [watch.subscriber, watch.handle]));
  if (notice.ownerSession && !recipients.has(notice.ownerSession)) recipients.set(notice.ownerSession, "");
  if (recipients.size === 0) return { sent: [], failed: [], skipped: "no-recipients" };
  if (notice.marker && !claimNoticeMarker(root, repoKey, notice, now)) return { sent: [], failed: [], skipped: "already-notified" };
  const text = releaseNoticeText(notice);
  const sent = [];
  const failed = [];
  for (const [to, toHandle] of recipients) {
    try {
      sent.push(sendReleaseNotice(root, { to, toHandle, text, now }).to);
    } catch (error) {
      failed.push({ to, error: String(error?.message ?? error) });
    }
  }
  return { sent, failed, skipped: "" };
}
