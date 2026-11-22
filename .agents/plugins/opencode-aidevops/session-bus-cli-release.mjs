// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Release watch and notification subcommands for `aidevops sessions`.
import * as store from "./session-bus-store.mjs";
import * as release from "./session-bus-release.mjs";
import { envSessionID } from "./session-bus-cli-input.mjs";
import { print } from "./session-bus-cli-commands.mjs";

// t18896: the watcher is the shell's own session, which needs a live presence
// record (a root session); a subagent shell should use the aidevops_sessions tool.
export function watchReleaseCommand({ root, options, out, env }) {
  const repo = options.positional[1];
  release.releaseRepoKey(repo);
  const sessionID = envSessionID(env);
  if (!store.isSafeId(sessionID)) throw new Error("watch-release runs inside an OpenCode session (or use the aidevops_sessions tool)");
  if (options.off) {
    const removed = release.removeReleaseWatch(root, repo, sessionID);
    return print(out, removed ? `Stopped watching releases for ${repo}.` : `Not watching releases for ${repo}.`, false);
  }
  const self = store.readPresence(root).find((record) => record.session_id === sessionID);
  if (!self) throw new Error("this shell's session has no live presence; use the aidevops_sessions tool from the root session");
  const watch = release.addReleaseWatch(root, repo, { session_id: sessionID, handle: self.handle });
  return print(out, options.json ? watch
    : `Watching releases for ${repo} until ${new Date(watch.expires_ms).toISOString()}: one info notice when a lane finalizes or its executor is first seen dead.`, options.json);
}

// Called by release-lane-liveness.sh with a 5 s timeout; its exit code is ignored there.
export function notifyReleaseCommand({ root, options, out }) {
  const result = release.notifyRelease(root, options);
  if (options.json) return print(out, result, true);
  const failed = result.failed.length > 0 ? `; ${result.failed.length} failed` : "";
  return print(out, result.skipped ? `No release notice sent (${result.skipped}).` : `Release notice sent to ${result.sent.length} session(s)${failed}.`, false);
}
