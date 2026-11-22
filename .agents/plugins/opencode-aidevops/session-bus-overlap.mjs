// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18895/GH#37248: overlap notices. When one of this process's root sessions
// shares an issue, PR, working branch or linked worktree with another live
// messageable session (interactive or pulse worker), it tells that session
// once, naming itself, and shows a toast here. Each side sends its own notice,
// so every message carries its real sender. A marker created exclusively under
// overlaps/ keeps it to one notice per direction and key, across processes and
// restarts. Sessions that only share a repo, or sit on a default branch in the
// canonical checkout, never overlap. AIDEVOPS_SESSION_OVERLAP_NOTICES=false
// turns notices off. Advisory only: nothing here blocks work.

import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

import * as store from "./session-bus-store.mjs";
import { showToast, warn } from "./session-bus-client.mjs";

// A record whose work keys are unchanged is rechecked at most once a minute,
// so a session that started first still notices a later arrival.
export const OVERLAP_RECHECK_MS = 60_000;
const MAX_TRACKED = 128;
const DEFAULT_BRANCHES = new Set(["main", "master", "develop", "trunk", "head"]);

export const overlapsDir = (root) => join(root, "overlaps");

export function overlapNoticesEnabled(env = process.env) {
  return !["0", "false", "no", "off"].includes(String(env.AIDEVOPS_SESSION_OVERLAP_NOTICES || "").trim().toLowerCase());
}

const lower = (value) => String(value || "").toLowerCase();
const sameRepo = (left, right) => Boolean(left.repo) && lower(left.repo) === lower(right.repo);
const workBranch = (record) => (record.branch && !DEFAULT_BRANCHES.has(lower(record.branch)) ? record.branch : "");

/** Work keys two presence records share: [{ id, label }]. */
export function overlapKeys(record, peer) {
  if (!record || !peer || record.session_id === peer.session_id) return [];
  const keys = [];
  if (sameRepo(record, peer)) {
    if (record.issue && record.issue === peer.issue) keys.push({ id: `issue:${lower(record.repo)}#${record.issue}`, label: `issue #${record.issue}` });
    if (record.pr && record.pr === peer.pr) keys.push({ id: `pr:${lower(record.repo)}#${record.pr}`, label: `PR #${record.pr}` });
    const branch = workBranch(record);
    if (branch && branch === peer.branch) keys.push({ id: `branch:${lower(record.repo)}:${branch}`, label: `branch ${branch}` });
  }
  // The same linked worktree; a shared branch above already names it.
  if (workBranch(record) && record.worktree && record.worktree === peer.worktree && !keys.some((key) => key.id.startsWith("branch:"))) {
    keys.push({ id: `worktree:${record.worktree}`, label: "the same worktree" });
  }
  return keys;
}

const markerFile = (root, fromID, toID, keyID) =>
  join(overlapsDir(root), `${createHash("sha256").update(`${fromID}\n${toID}\n${keyID}`).digest("hex").slice(0, 32)}.json`);

/** Exclusive create: true only for the first caller per direction and key. */
export function claimOverlap(root, fromID, toID, keyID, now = Date.now()) {
  store.ensureDir(overlapsDir(root));
  try {
    writeFileSync(markerFile(root, fromID, toID, keyID), `${JSON.stringify({ v: 1, from: fromID, to: toID, key: keyID, created_ms: now })}\n`, { flag: "wx", mode: 0o600 });
    return true;
  } catch (error) {
    if (error?.code === "EEXIST") return false;
    throw error;
  }
}

/** The notice the peer receives; it names this session and how to reach it. */
export function overlapText(record, keys) {
  const shared = keys.map((key) => key.label).join(", ");
  const repo = record.repo ? ` in ${record.repo}` : "";
  const worker = record.kind === "headless";
  const who = worker ? `pulse worker ${record.handle}` : `session ${record.handle}`;
  const reach = worker
    ? "It reads messages at its next tool result and answers from its shell."
    : "Ask it if the split of work is unclear.";
  return [
    `Overlap notice: ${who} is also working on ${shared}${repo}.`,
    `Compare approaches before continuing so the two do not compete: aidevops sessions show ${record.handle}. ${reach}`,
    "The issue's assignee and status:claimed label on GitHub decide ownership.",
  ].join(" ");
}

function rememberCheck(checked, sessionID, value) {
  checked.delete(sessionID);
  checked.set(sessionID, value);
  while (checked.size > MAX_TRACKED) checked.delete(checked.keys().next().value);
}

export class OverlapNotifier {
  /** @param {object} options - { root, client, now, env, fromFor(sessionID) -> sender identity } */
  constructor({ root, client, now = () => Date.now(), env = process.env, fromFor }) {
    Object.assign(this, { root, client, now, fromFor });
    this.enabled = overlapNoticesEnabled(env);
    this.checked = new Map();
  }

  /** After a presence write: check when the record's work keys changed, or once a minute. Returns notices sent. */
  observe(record) {
    if (!this.enabled || !store.isMessageable(record)) return 0;
    const signature = [lower(record.repo), record.issue, record.pr, record.branch, record.worktree].join("|");
    const last = this.checked.get(record.session_id);
    if (last && last.signature === signature && this.now() - last.at < OVERLAP_RECHECK_MS) return 0;
    rememberCheck(this.checked, record.session_id, { signature, at: this.now() });
    try {
      return this.check(record);
    } catch (error) {
      warn("overlap check", error);
      return 0;
    }
  }

  /** An idle session writes no presence, so the bus poll rechecks its roots (each at most once a minute) for later arrivals. */
  recheck(bus) {
    for (const state of bus.sessions.values()) {
      if (state.lastWriteMs && bus.tree.isKnownRoot(state.sessionID)) this.observe(bus.record(state));
    }
  }

  check(record) {
    let sent = 0;
    for (const peer of store.readPresence(this.root)) {
      if (!store.isMessageable(peer)) continue;
      const fresh = overlapKeys(record, peer)
        .filter((key) => claimOverlap(this.root, record.session_id, peer.session_id, key.id, this.now()));
      if (fresh.length > 0) sent += this.notify(record, peer, fresh);
    }
    return sent;
  }

  notify(record, peer, keys) {
    const labels = keys.map((key) => key.label).join(", ");
    void showToast(this.client, `Overlap with ${peer.handle}`, `Both on ${labels}. Check with: aidevops sessions show ${peer.handle}`);
    try {
      store.sendMessage(this.root, {
        from: this.fromFor(record.session_id),
        to: peer.session_id,
        toHandle: peer.handle,
        type: "info",
        text: overlapText(record, keys),
      });
      return 1;
    } catch (error) {
      // Not retried: the marker stays, and the toast already showed here.
      warn("overlap notice", error);
      return 0;
    }
  }
}
