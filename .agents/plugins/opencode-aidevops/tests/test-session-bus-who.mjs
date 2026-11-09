// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18895/GH#37248: `who` matching and overlap notices.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";

import * as store from "../session-bus-store.mjs";
import { main as cliMain } from "../session-bus-cli.mjs";
import { OVERLAP_RECHECK_MS, OverlapNotifier, overlapKeys } from "../session-bus-overlap.mjs";

let root;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "session-bus-who-"));
});
afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

function livePresence(id, extra = {}) {
  const record = {
    v: store.BUS_VERSION, session_id: id, pid: process.pid, start_token: store.startToken(process.pid),
    kind: "tui", messageable: true, repo: "owner/repo", worktree: `/w/${id}`, branch: "main",
    title: "", issue: null, pr: null, status: "idle", handle: `repo-${id.slice(-2)}`, ...extra,
  };
  store.writePresence(root, record);
  return record;
}

const capture = () => {
  const chunks = [];
  return { chunks, write: (chunk) => chunks.push(String(chunk)), text: () => chunks.join("") };
};

test("matchSessions returns every live session on an issue, PR, repo or path, scoped and without self", () => {
  const records = [
    { session_id: "ses_whoA01", handle: "repo-1", issue: 1, pr: null, repo: "o/r", worktree: "/w/a", branch: "feature/x" },
    { session_id: "ses_whoB02", handle: "repo-pr7", issue: null, pr: 7, repo: "o/r", worktree: "/w/b", branch: "feature/y" },
    { session_id: "ses_whoC03", handle: "s-1", issue: 1, pr: null, repo: "o/s", worktree: "/w/c", branch: "main" },
  ];
  const ids = (target, options) => store.matchSessions(records, target, options).map((record) => record.session_id);
  assert.deepEqual(ids("#1"), ["ses_whoA01", "ses_whoC03"]);
  assert.deepEqual(ids("GH#1", { repo: "O/R" }), ["ses_whoA01"], "issue numbers are per repo");
  assert.deepEqual(ids("PR#7"), ["ses_whoB02"]);
  assert.deepEqual(ids("o/r"), ["ses_whoA01", "ses_whoB02"]);
  assert.deepEqual(ids("r"), ["ses_whoA01", "ses_whoB02"], "repo name");
  assert.deepEqual(ids("/w/a/src/x.js"), ["ses_whoA01"], "file inside a worktree");
  assert.deepEqual(ids("src/x.js", { cwd: "/w/b" }), ["ses_whoB02"], "relative path from cwd");
  assert.deepEqual(ids("/w"), [], "a parent directory is not inside any worktree");
  assert.deepEqual(ids("#1", { selfID: "ses_whoA01" }), ["ses_whoC03"], "the caller is excluded");
  assert.throws(() => store.matchSessions(records, " "), /missing target/);
});

test("CLI who prints rows or JSON for the union of targets; no match is quiet on stdout", () => {
  livePresence("ses_cliW01", { issue: 5, handle: "repo-5", branch: "feature/a", current_task: "fix parser" });
  livePresence("ses_cliW02", { issue: 5, handle: "repo-5-worker", kind: "headless", worker: { repo: "owner/repo", issue: 5 } });
  livePresence("ses_cliW03", { pr: 8, handle: "repo-pr8" });
  const json = capture();
  cliMain(["who", "#5", "PR#8", "#5", "--repo", "owner/repo", "--json"], { root, env: {}, out: json, err: capture() });
  assert.deepEqual(JSON.parse(json.text()).map((record) => record.session_id).sort(), ["ses_cliW01", "ses_cliW02", "ses_cliW03"]);

  const rows = capture();
  cliMain(["who", "#5"], { root, env: { OPENCODE_SESSION_ID: "ses_cliW01" }, out: rows, err: capture() });
  assert.equal(rows.text().trim().split("\n").length, 1, "the calling session is excluded");
  assert.match(rows.text(), /^repo-5-worker \[worker\] · idle · #5 · owner\/repo@main · worktree ses_cliW02/);

  const quiet = capture();
  const note = capture();
  cliMain(["who", "#404"], { root, env: {}, out: quiet, err: note });
  assert.equal(quiet.text(), "");
  assert.match(note.text(), /No other live session is working on #404/);
  assert.throws(() => cliMain(["who"], { root, env: {}, out: quiet, err: note }), /who needs a target/);
});

test("overlap keys: same issue, PR, working branch or worktree; never a shared repo or default branch alone", () => {
  const base = { session_id: "ses_keyA01", repo: "o/r", worktree: "/w/a", branch: "feature/a", issue: 3, pr: null };
  const keys = (peer) => overlapKeys(base, { session_id: "ses_keyB02", ...peer }).map((key) => key.id);
  assert.deepEqual(keys({ repo: "o/r", worktree: "/w/b", branch: "feature/b", issue: 3 }), ["issue:o/r#3"]);
  assert.deepEqual(keys({ repo: "o/s", worktree: "/w/b", branch: "feature/b", issue: 3 }), [], "issue numbers are per repo");
  assert.deepEqual(keys({ repo: "o/r", worktree: "/w/b", branch: "feature/a" }), ["branch:o/r:feature/a"]);
  assert.deepEqual(keys({ repo: "o/r", worktree: "/w/a", branch: "feature/a" }), ["branch:o/r:feature/a"], "a shared branch already names the worktree");
  assert.deepEqual(keys({ repo: "o/r", worktree: "/w/b", branch: "main" }), [], "same repo only");
  const onMain = { ...base, branch: "main", issue: null };
  assert.deepEqual(overlapKeys(onMain, { session_id: "ses_keyB02", repo: "o/r", worktree: "/w/a", branch: "main" }), [],
    "sessions in the canonical checkout on main are not an overlap");
  assert.deepEqual(overlapKeys(base, base), [], "never with itself");
});

test("overlap notices go once per direction and key, survive restarts and can be turned off", () => {
  const toasts = [];
  const client = { tui: { showToast: async ({ body }) => toasts.push(body) } };
  const a = livePresence("ses_ovlA01", { issue: 9, branch: "feature/a", handle: "repo-9" });
  const b = livePresence("ses_ovlB02", { issue: 9, branch: "feature/b", handle: "repo-9-worker", kind: "headless" });
  const c = livePresence("ses_ovlC03", { branch: "main" });
  const handles = { [a.session_id]: a.handle, [b.session_id]: b.handle };
  const fromFor = (id) => ({ session_id: id, handle: handles[id], repo: "owner/repo", branch: "", origin: "opencode" });
  let now = 1_000;
  const notifier = new OverlapNotifier({ root, client, now: () => now, env: {}, fromFor });

  assert.equal(notifier.observe(a), 1);
  assert.equal(notifier.observe(a), 0, "unchanged keys are not rechecked within a minute");
  now += OVERLAP_RECHECK_MS;
  assert.equal(notifier.observe(a), 0, "the marker stops a repeat");
  assert.equal(notifier.observe(b), 1, "the other side sends its own notice");

  const inbox = (id) => store.pendingMessages(root, id).map((entry) => entry.message);
  const [toWorker] = inbox(b.session_id);
  assert.equal(inbox(b.session_id).length, 1);
  assert.equal(toWorker.type, "info");
  assert.equal(toWorker.from.session_id, a.session_id);
  assert.match(toWorker.text, /session repo-9 is also working on issue #9 in owner\/repo/);
  const [toSession] = inbox(a.session_id);
  assert.match(toSession.text, /pulse worker repo-9-worker is also working on issue #9/);
  assert.equal(inbox(c.session_id).length, 0, "a session that only shares the repo gets nothing");
  assert.deepEqual(toasts.map((toast) => toast.title), ["Overlap with repo-9-worker", "Overlap with repo-9"]);

  const restarted = new OverlapNotifier({ root, client, now: () => now, env: {}, fromFor });
  assert.equal(restarted.observe(a), 0, "markers persist across a restart");

  const d = livePresence("ses_ovlD04", { issue: 9, branch: "feature/d" });
  const off = new OverlapNotifier({ root, client, now: () => now, env: { AIDEVOPS_SESSION_OVERLAP_NOTICES: "false" }, fromFor });
  assert.equal(off.observe(d), 0);
  assert.equal(inbox(a.session_id).length, 1, "disabled notices send nothing");

  // Markers age by file mtime (real time), like messages by their file names.
  store.pruneBus(root, Date.now() + store.LIMITS.retentionMs + 60_000);
  assert.equal(new OverlapNotifier({ root, client, now: () => now, env: {}, fromFor }).observe(a) >= 1, true,
    "expired markers are pruned with messages");
});
