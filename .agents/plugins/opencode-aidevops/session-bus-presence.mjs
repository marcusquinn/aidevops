// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: presence publishing for the session-bus runtime: process
// kind, cached git facts, record building and throttled writes.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

import * as store from "./session-bus-store.mjs";
import { warn } from "./session-bus-client.mjs";
import { stripSessionAddressToken } from "./session-title-suffix.mjs";

const execFileAsync = promisify(execFile);
const PRESENCE_THROTTLE_MS = 10_000;
const GIT_TTL_MS = 60_000;

// Subcommands that load plugins but are not a TUI, server or ACP host.
const NON_INTERACTIVE_COMMANDS = new Set([
  "run", "github", "pr", "debug", "models", "stats", "export", "import",
  "upgrade", "uninstall", "auth", "agent", "mcp", "session", "generate", "plugin",
]);

const PROCESS_KINDS = { serve: "serve", web: "serve", acp: "acp" };

export function processKind(argv = process.argv, { headless = false } = {}) {
  if (headless) return "headless";
  const command = argv.slice(2).find((arg) => !arg.startsWith("-"));
  if (Object.hasOwn(PROCESS_KINDS, command ?? "")) return PROCESS_KINDS[command];
  return NON_INTERACTIVE_COMMANDS.has(command) ? "cli" : "tui";
}

export function parseRepoSlug(url) {
  const match = /[:/]([^/:\s]+\/[^/\s]+?)(?:\.git)?\/?$/.exec(String(url || "").trim());
  return match ? match[1] : "";
}

const REPO_SLUG = /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/;
const SAFE_LABEL = /^[A-Za-z0-9_.:-]{1,80}$/;

function attemptStartEpoch(value, now) {
  const text = String(value || "");
  if (/^\d{19}$/.test(text)) return Math.floor(Number(text.slice(0, 10)));
  if (/^\d{10}$/.test(text)) return Number(text);
  return Math.floor((now - process.uptime() * 1000) / 1000);
}

/**
 * t18905: the dispatch facts of a pulse worker, from the environment
 * pulse-dispatch-worker-launch.sh sets, or null outside a dispatched worker.
 * Readers (the pulse relay, `list`) use them to find the worker's issue.
 */
export function workerContext(env = process.env, now = Date.now()) {
  const issue = Number(env.WORKER_ISSUE_NUMBER);
  const repo = String(env.WORKER_REPO_SLUG || "");
  if (!Number.isSafeInteger(issue) || issue <= 0 || !REPO_SLUG.test(repo)) return null;
  const label = (value) => (SAFE_LABEL.test(String(value || "")) ? String(value) : "");
  return {
    issue,
    repo,
    worker_id: label(env.AIDEVOPS_WORKER_ID),
    attempt_id: label(env.AIDEVOPS_ATTEMPT_ID),
    tier: label(env.AIDEVOPS_DISPATCH_TIER),
    started_epoch: attemptStartEpoch(env.AIDEVOPS_ATTEMPT_STARTED_AT, now),
  };
}

const emptyGit = (worktree = "") => ({ worktree, branch: "", repo: "" });

const gitChanged = (left, right) =>
  left.branch !== right.branch || left.repo !== right.repo || left.worktree !== right.worktree;

/** Git facts per directory, refreshed in the background at most once a minute. */
export class GitInfoCache {
  constructor({ now, git, onChange = () => {} }) {
    this.now = now;
    this.git = git || ((args) => execFileAsync("git", args, { timeout: 3000, encoding: "utf8" }));
    this.onChange = onChange;
    this.entries = new Map();
  }

  get(directory) {
    if (!directory) return emptyGit();
    const cached = this.entries.get(directory);
    if (this.stale(cached)) this.refresh(directory, cached);
    return cached || emptyGit(directory);
  }

  stale(cached) {
    return !cached || (!cached.pending && this.now() - cached.at > GIT_TTL_MS);
  }

  refresh(directory, previous) {
    const entry = { ...(previous || emptyGit(directory)), at: this.now(), pending: true };
    this.entries.set(directory, entry);
    const run = (args) => this.git(["-C", directory, ...args]).catch(() => null);
    Promise.all([
      run(["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"]),
      previous?.repo ? Promise.resolve(null) : run(["config", "--get", "remote.origin.url"]),
    ]).then(([revParse, remote]) => this.settle(directory, entry, revParse, remote));
  }

  settle(directory, entry, revParse, remote) {
    const [worktree = "", branch = ""] = String(revParse?.stdout || "").trim().split("\n");
    const next = {
      worktree: worktree || entry.worktree,
      branch: branch || entry.branch,
      repo: remote ? parseRepoSlug(remote.stdout) : entry.repo,
      at: this.now(),
      pending: false,
    };
    this.entries.set(directory, next);
    if (gitChanged(next, entry)) this.onChange(directory);
  }
}

/** Builds and writes this process's presence records; one writer per record. */
export class PresencePublisher {
  constructor({ root, kind, messageable, directory, now, timers, gitInfo, remote = null, worker = null, onWrite = () => {} }) {
    Object.assign(this, { root, kind, messageable, directory, now, timers, gitInfo, remote, worker, onWrite });
    this.token = null;
    this.disposed = false;
  }

  processToken() {
    if (this.token === null) this.token = store.startToken(process.pid);
    return this.token;
  }

  record(state) {
    const directory = state.directory || this.directory;
    const git = this.gitInfo.get(directory);
    const refs = store.parseTitleRefs(state.title);
    const base = {
      v: store.BUS_VERSION,
      session_id: state.sessionID,
      // GH#37630: the title's `· @xxxxxx` address token repeats session_id.
      title: stripSessionAddressToken(state.title).slice(0, 200),
      pid: process.pid,
      start_token: this.processToken(),
      kind: this.kind,
      messageable: this.messageable,
      repo: git.repo,
      worktree: git.worktree,
      branch: git.branch,
      directory,
      issue: refs.issue ?? this.worker?.issue ?? null,
      pr: refs.pr,
      status: state.status,
      current_task: state.task,
      last_activity_epoch: Math.floor(state.lastActivityMs / 1000),
      // t18898: additive, only for remote-hosted sessions so local records stay unchanged.
      ...(this.remote ? { interface: this.remote.interface, ...(this.remote.agent ? { agent: this.remote.agent } : {}) } : {}),
      // t18905: additive; dispatch facts for pulse workers, and the tool running now.
      ...(this.worker ? { worker: this.worker } : {}),
      ...(state.tool ? { tool: { name: state.tool.name, since_epoch: Math.floor(state.tool.sinceMs / 1000) } } : {}),
    };
    return { ...base, handle: store.deriveHandle(base), updated_epoch: Math.floor(this.now() / 1000) };
  }

  clearTimer(state) {
    if (state.writeTimer) this.timers.clearTimeout(state.writeTimer);
    state.writeTimer = null;
  }

  write(state) {
    if (this.disposed) return false;
    this.clearTimer(state);
    const record = this.record(state);
    if (!record.start_token) return false;
    try {
      store.writePresence(this.root, record);
      state.lastWriteMs = this.now();
      state.handle = record.handle;
    } catch (error) {
      warn("presence write", error);
      return false;
    }
    // t18895: overlap detection reads the record just written; it never fails the write.
    this.onWrite(record);
    return true;
  }

  /** Write now when urgent; otherwise at most once per throttle window. */
  schedule(state, urgent) {
    const wait = PRESENCE_THROTTLE_MS - (this.now() - state.lastWriteMs);
    if (urgent || wait <= 0) return this.write(state);
    if (!state.writeTimer) {
      state.writeTimer = this.timers.setTimeout(() => this.write(state), wait);
      state.writeTimer?.unref?.();
    }
    return false;
  }

  /** `quiet` at exit: readers already ignore records whose process has exited. */
  remove(sessionID, { quiet = false } = {}) {
    try {
      store.removePresence(this.root, sessionID);
    } catch (error) {
      if (!quiet) warn("presence remove", error);
    }
  }
}
