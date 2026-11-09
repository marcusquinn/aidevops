// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: resolve a session-bus `to` argument (session ID, handle,
// #issue, PR#n, worktree, repo, title words, or a t18892 channel binding) to
// one live presence record.

import { homedir } from "node:os";
import { basename, join } from "node:path";

import { busRoot, isSafeId } from "./session-bus-files.mjs";
import {
  CHANNEL_TARGET_PREFIX,
  channelLabel,
  isChannelTarget,
  parseChannelRef,
  readBinding,
} from "./session-bus-bindings.mjs";

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

// t18892: `channel:<app>:<channel>` resolves only through its binding, and
// only to a live session. A dead bound session is an error with code 3
// (`notLive`); it never falls back to another session or to the inbox.
function channelResult(records, query, selfID, root) {
  let chat;
  try {
    chat = parseChannelRef(query.slice(CHANNEL_TARGET_PREFIX.length));
  } catch (error) {
    return { error: `invalid target "${query}": ${error.message}` };
  }
  const label = channelLabel(chat);
  const binding = readBinding(root, chat.app, chat.channel);
  if (!binding) return { error: `${label} is not bound; run: aidevops sessions bind ${chat.app} ${chat.channel} <target>` };
  if (binding.session_id === selfID) return { error: SELF_TARGET };
  const record = records.find((candidate) => candidate.session_id === binding.session_id);
  if (!record) {
    return { error: `${label} is bound to ${binding.session_id}, which is not live; rebind it or launch a new session`, notLive: true, binding };
  }
  return { record, binding };
}

/**
 * Resolve `to` against live presence records. `root` is only read for
 * `channel:` targets (default: the bus root from the environment).
 */
export function resolveTarget(records, to, selfID = "", { root = busRoot() } = {}) {
  const query = String(to || "").trim();
  if (!query) return { error: "missing target: pass `to` (session ID, handle, #issue, PR#n, repo, worktree or channel:<app>:<channel>)" };
  if (isChannelTarget(query)) return channelResult(records, query, selfID, root);
  for (const matches of TARGET_TIERS) {
    const found = records.filter((record) => matches(record, query));
    if (found.length > 0) return tierResult(found, query, selfID);
  }
  return offlineResult(query, selfID);
}
