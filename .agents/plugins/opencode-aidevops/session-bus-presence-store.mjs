// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: session-bus presence records and process liveness. One
// record per root session, written only by the process that owns it.

import { rmSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import { spawnSync } from "node:child_process";

import {
  BUS_VERSION,
  MESSAGEABLE_KINDS,
  isSafeId,
  listDir,
  presenceDir,
  readJson,
  writeJsonAtomic,
} from "./session-bus-files.mjs";

// ---------------------------------------------------------------------------
// Liveness. One `ps` call for every live PID, run under the same locale and
// time zone in every process, so the plugin (writer) and CLI (reader) produce
// identical tokens for the same process generation.
// ---------------------------------------------------------------------------

function pidExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

let psPresent;
function existsPs() {
  if (psPresent === undefined) {
    try {
      psPresent = statSync("/bin/ps").isFile();
    } catch {
      psPresent = false;
    }
  }
  return psPresent;
}

const isLivePid = (pid) => Number.isSafeInteger(pid) && pid > 0 && pidExists(pid);

export function startTokens(pids, { spawn = spawnSync } = {}) {
  const tokens = new Map();
  const alive = [...new Set(pids)].filter(isLivePid);
  if (alive.length === 0) return tokens;
  const result = spawn(existsPs() ? "/bin/ps" : "ps", ["-o", "pid=,lstart=", "-p", alive.join(",")], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C", TZ: "UTC" },
    timeout: 3000,
  });
  for (const line of String(result?.stdout || "").split("\n")) {
    const match = /^\s*(\d+)\s+(\S.*)$/.exec(line);
    if (match) tokens.set(Number(match[1]), `ps:${match[2].trim().replace(/\s+/g, " ")}`);
  }
  return tokens;
}

export function startToken(pid, options) {
  return startTokens([pid], options).get(pid) || "";
}

// ---------------------------------------------------------------------------
// Presence
// ---------------------------------------------------------------------------

export function parseTitleRefs(title) {
  const text = String(title || "");
  const issue = /\b(?:Issue|GH)\s*#(\d{1,7})\b/i.exec(text);
  const pr = /\bPR\s*#(\d{1,7})\b/i.exec(text);
  return { issue: issue ? Number(issue[1]) : null, pr: pr ? Number(pr[1]) : null };
}

function handleBase(repo, worktree) {
  const name = repo ? repo.split("/").pop() : basename(String(worktree || ""));
  return String(name || "session")
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40) || "session";
}

export function deriveHandle({ repo, worktree, issue, pr, session_id: sessionID, kind }) {
  const base = handleBase(repo, worktree);
  // t18905: a worker and an interactive session on one issue keep distinct handles.
  const role = kind === "headless" ? "-worker" : "";
  if (issue) return `${base}-${issue}${role}`;
  if (pr) return `${base}-pr${pr}${role}`;
  return `${base}-${String(sessionID || "").slice(-6).toLowerCase()}`;
}

export function writePresence(root, record) {
  if (!isSafeId(record?.session_id)) return false;
  writeJsonAtomic(join(presenceDir(root), `${record.session_id}.json`), record);
  return true;
}

export function removePresence(root, sessionID) {
  if (!isSafeId(sessionID)) return;
  rmSync(join(presenceDir(root), `${sessionID}.json`), { force: true });
}

function presenceRecords(root, sweep) {
  const dir = presenceDir(root);
  const records = [];
  for (const name of listDir(dir).filter((file) => file.endsWith(".json"))) {
    const record = readJson(join(dir, name));
    if (record?.v === BUS_VERSION && isSafeId(record.session_id)) records.push(record);
    else if (sweep) rmSync(join(dir, name), { force: true });
  }
  return records;
}

// Dead means the PID is gone, or `ps` reports a different start token (the
// PID was reused). A live PID with no token (`ps` failed, timed out or lacks
// `lstart`) proves nothing, so it falls back to PID liveness and is kept.
function isLiveRecord(record, tokens) {
  if (!isLivePid(record.pid)) return false;
  const token = tokens.get(record.pid);
  return !token || token === record.start_token;
}

/**
 * Live presence records. A recycled PID never revives a dead session while
 * `ps` can read start times. `sweep` deletes dead records; only the plugin
 * startup and the CLI use it.
 */
export function readPresence(root, { sweep = false, tokens: tokenFn = startTokens } = {}) {
  const records = presenceRecords(root, sweep);
  const tokens = tokenFn(records.map((record) => record.pid));
  const live = [];
  for (const record of records) {
    if (isLiveRecord(record, tokens)) live.push(record);
    else if (sweep) removePresence(root, record.session_id);
  }
  return live;
}

export function isMessageable(record) {
  return Boolean(record) && record.messageable === true && MESSAGEABLE_KINDS.includes(record.kind);
}

/** t18905: a messageable pulse worker; it reads messages at tool results but is never woken. */
export function isWorker(record) {
  return isMessageable(record) && record.kind === "headless";
}
