// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t19157/GH#39240: `aidevops sessions watch-issue` and `watches`. The watcher
// is the shell's own root session; the pulse relay reads `watches --all --json`.
import * as store from "./session-bus-store.mjs";
import * as watches from "./session-bus-issue-watch.mjs";
import { envSessionID } from "./session-bus-cli-input.mjs";
import { print, printLines } from "./session-bus-cli-commands.mjs";

const ref = (watch) => `${watch.repo}#${watch.number}`;

function selfRecord(root, env) {
  const sessionID = envSessionID(env);
  if (!store.isSafeId(sessionID)) throw new Error("watch-issue runs inside an OpenCode session (or use the aidevops_sessions tool)");
  const self = store.readPresence(root).find((record) => record.session_id === sessionID);
  if (!self) throw new Error("this shell's session has no live presence; use the aidevops_sessions tool from the root session");
  return self;
}

export function watchIssueCommand({ root, options, out, env }) {
  const target = options.positional[1];
  const self = selfRecord(root, env);
  const defaultRepo = options.repo || self.repo;
  if (options.off) {
    const removed = watches.removeIssueWatch(root, target, self.session_id, defaultRepo);
    return print(out, removed ? `Stopped watching ${target}.` : `Not watching ${target}.`, false);
  }
  const watch = watches.addIssueWatch(root, target, { ...self, repo: defaultRepo }, { fresh: options.fresh });
  return print(out, options.json ? watch : `Watching ${ref(watch)} until ${new Date(watch.expires_ms).toISOString()}: `
    + "one batched info pointer per relay pass when its status, assignees, state or comments change.", options.json);
}

export function watchesCommand({ root, options, out, env }) {
  const list = options.all ? watches.allIssueWatches(root) : watches.sessionIssueWatches(root, selfRecord(root, env).session_id);
  if (options.json) return print(out, list, true);
  const lines = list.map((watch) => `${ref(watch)}${options.all ? ` → ${watch.handle || watch.subscriber}` : ""} until ${new Date(watch.expires_ms).toISOString()}`);
  return printLines(out, lines, "No issue watches.");
}
