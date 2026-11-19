// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t19157/GH#39240: the `watch-issue` action of the aidevops_sessions tool
// (session-bus-tool.mjs); session-bus-cli-watch.mjs is the CLI counterpart.
// The watcher is always the caller's root session; `#N` uses its repo.
import * as issueWatch from "./session-bus-issue-watch.mjs";

const until = (watch) => new Date(watch.expires_ms).toISOString();

function listWatches(root, sessionID) {
  const list = issueWatch.sessionIssueWatches(root, sessionID);
  if (list.length === 0) return "No issue watches.";
  return ["Issue watches:", ...list.map((watch) => `- ${watch.repo}#${watch.number} until ${until(watch)}`)].join("\n");
}

export function watchIssueAction(root, sender, args) {
  const target = String(args.to || "").trim();
  if (!target) return listWatches(root, sender.sessionID);
  if (args.text === "off") {
    return issueWatch.removeIssueWatch(root, target, sender.sessionID, sender.record.repo)
      ? `Stopped watching ${target}.` : `Not watching ${target}.`;
  }
  if (args.text) throw new Error("watch-issue takes to=owner/repo#N, and text only as \"off\"");
  const watch = issueWatch.addIssueWatch(root, target, sender.record);
  return `Watching ${watch.repo}#${watch.number} until ${until(watch)}: the pulse relay sends one batched info pointer per pass when its status, assignees, state or comments change. Pointers never wake this session.`;
}
