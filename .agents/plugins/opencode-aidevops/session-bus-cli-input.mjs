// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: who a CLI message is from, and its text. Subcommands in
// session-bus-cli-commands.mjs take both from here.

import { readFileSync } from "node:fs";

import * as store from "./session-bus-store.mjs";

/** Message text: --text-file, `-` for stdin, or the positional words. */
export function readText(options, words) {
  if (options.textFile) return readFileSync(options.textFile, "utf8");
  if (words.length === 1 && words[0] === "-") return readFileSync(0, "utf8");
  return words.join(" ");
}

export const envSessionID = (env) => env.AIDEVOPS_OPENCODE_SESSION_ID || env.OPENCODE_SESSION_ID || "";

function chatSender(origin) {
  const chat = store.parseChatOrigin(origin);
  if (!chat) throw new Error("--origin must look like chat:<app>:<channel>");
  return { session_id: "", handle: `chat:${chat.app}`, repo: "", branch: "", origin };
}

// Inside an OpenCode bash tool the shell inherits the session ID, so a CLI
// send is attributed to that session; elsewhere it comes from shell:<user>.
export function shellSender(root, env) {
  const raw = envSessionID(env);
  const sessionID = store.isSafeId(raw) ? raw : "";
  const self = sessionID ? store.readPresence(root).find((record) => record.session_id === sessionID) : null;
  const fallback = raw ? `session-${raw.slice(-6)}` : `shell:${env.USER || "user"}`;
  return {
    session_id: sessionID,
    handle: self?.handle || fallback,
    repo: self?.repo || "",
    branch: self?.branch || "",
    origin: "cli",
  };
}

// t18905: a named sessionless sender, such as the pulse relay. The label is
// attribution only (same-user shells are equally trusted); it also gives the
// sender its own rate-limit key, cli-<label>.
const SENDER_LABEL = /^[a-z0-9][a-z0-9-]{0,31}$/;

function labelledSender(label) {
  if (!SENDER_LABEL.test(String(label || ""))) throw new Error("--sender must be 1-32 lowercase letters, digits or dashes");
  return { session_id: "", handle: label, repo: "", branch: "", origin: `cli:${label}` };
}

function senderFrom(root, options, env) {
  if (options.origin && options.sender) throw new Error("use --origin or --sender, not both");
  if (options.origin) return chatSender(options.origin);
  return options.sender ? labelledSender(options.sender) : shellSender(root, env);
}

/** The sender for `send`/`ask`. A plain `ask --wait` has no session, so its reply lands in outbox/cli. */
export function cliSender(root, options, env) {
  if (options.wait && !options.origin && !options.sender) {
    return { session_id: "", handle: `shell:${env.USER || "user"}`, repo: "", branch: "", origin: "cli" };
  }
  return senderFrom(root, options, env);
}
