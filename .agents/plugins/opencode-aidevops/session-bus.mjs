// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: OpenCode session bus runtime, one per plugin instance.
// - Presence: one record per root session this process owns. It is written
//   when the session's state changes, throttled for activity, and removed on
//   exit.
// - Delivery uses only channels that persist in the session (Phase 0 verified
//   on OpenCode v1.19.5):
//     busy -> appended to the next tool result (tool.execute.after)
//     next user turn -> synthetic part on the user message (chat.message)
//     idle + ask/reply/idle-notice -> client.session.promptAsync (wake)
//   A toast announces each arrival. A 5s poll drives toasts and wakes. Nothing
//   runs while the inboxes are empty, apart from one readdir per owned session.
// Store, limits and framing: session-bus-store.mjs; docs: reference/session-bus.md.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

import * as store from "./session-bus-store.mjs";
import { sessionIDFrom } from "./session-turn-state.mjs";

const execFileAsync = promisify(execFile);
const POLL_MS = 5000;
const PRESENCE_THROTTLE_MS = 10_000;
const GIT_TTL_MS = 60_000;
const SWEEP_DELAY_MS = 3000;
const MAX_TRACKED = 64;
const MAX_TOASTED = 256;
const HOUR_MS = 60 * 60 * 1000;

// Subcommands that load plugins but are not a TUI, server or ACP host.
const NON_INTERACTIVE_COMMANDS = new Set([
  "run", "github", "pr", "debug", "models", "stats", "export", "import",
  "upgrade", "uninstall", "auth", "agent", "mcp", "session", "generate", "plugin",
]);

export function processKind(argv = process.argv, { headless = false } = {}) {
  if (headless) return "headless";
  const command = argv.slice(2).find((arg) => !arg.startsWith("-"));
  if (command === "serve" || command === "web") return "serve";
  if (command === "acp") return "acp";
  if (NON_INTERACTIVE_COMMANDS.has(command)) return "cli";
  return "tui";
}

export function parseRepoSlug(url) {
  const match = /[:/]([^/:\s]+\/[^/\s]+?)(?:\.git)?\/?$/.exec(String(url || "").trim());
  return match ? match[1] : "";
}

function firstInProgressTodo(todos) {
  if (!Array.isArray(todos)) return "";
  const todo = todos.find((item) => item?.status === "in_progress");
  return String(todo?.content || "").replace(/\s+/g, " ").trim().slice(0, 160);
}

function responseError(result) {
  return result?.error || (result?.response && result.response.ok === false ? `HTTP ${result.response.status}` : null);
}

const unwrap = (result) => (result && typeof result === "object" && "data" in result ? result.data : result);

const STATUS_FROM_EVENT = {
  "session.idle": () => "idle",
  "permission.asked": () => "permission",
  "permission.updated": () => "permission",
  "permission.replied": () => "busy",
  "session.status": (props) => {
    const type = String(props.status?.type || "").toLowerCase();
    if (type === "busy" || type === "retry") return "busy";
    return type === "idle" ? "idle" : "";
  },
};

const ACTIVITY_EVENTS = new Set(["message.updated", "message.part.updated", "todo.updated"]);

export function isWakeEligible(message) {
  if (!message || message.hops >= store.LIMITS.maxWakeHops) return false;
  if (store.parseChatOrigin(message.from?.origin)) return false;
  return message.type === "ask" || message.type === "reply" || message.type === "idle-notice";
}

class SessionBus {
  constructor({ client, directory = "", root = store.busRoot(), kind = "tui", now = () => Date.now(), timers = globalThis, git } = {}) {
    this.client = client;
    this.directory = directory;
    this.root = root;
    this.kind = kind;
    this.messageable = store.MESSAGEABLE_KINDS.includes(kind);
    this.now = now;
    this.timers = timers;
    this.git = git || ((args) => execFileAsync("git", args, { timeout: 3000, encoding: "utf8" }));
    this.sessions = new Map();
    this.roots = new Map();
    this.parents = new Map();
    this.lookups = new Map();
    this.gitInfo = new Map();
    this.toasted = new Set();
    this.token = null;
    this.timer = null;
    this.ticking = false;
    this.disposed = false;
  }

  start() {
    const sweep = this.timers.setTimeout(() => this.sweep(), SWEEP_DELAY_MS);
    sweep?.unref?.();
    if (this.messageable) {
      this.timer = this.timers.setInterval(() => this.tick(), POLL_MS);
      this.timer?.unref?.();
    }
    return this;
  }

  sweep() {
    try {
      store.readPresence(this.root, { sweep: true });
      store.pruneBus(this.root, this.now());
    } catch (error) {
      warn("sweep", error);
    }
  }

  dispose() {
    this.disposed = true;
    if (this.timer) this.timers.clearInterval(this.timer);
    for (const sessionID of this.sessions.keys()) {
      try {
        store.removePresence(this.root, sessionID);
      } catch {
        // Readers ignore records whose process has exited.
      }
    }
  }

  // -------------------------------------------------------------------------
  // Session identity
  // -------------------------------------------------------------------------

  rememberInfo(info) {
    if (!store.isSafeId(info?.id)) return;
    this.roots.set(info.id, !info.parentID);
    if (info.parentID) this.parents.set(info.id, info.parentID);
    else {
      const state = this.state(info.id);
      if (typeof info.title === "string") state.title = info.title;
      if (info.directory) state.directory = info.directory;
    }
    while (this.roots.size > MAX_TRACKED * 4) this.roots.delete(this.roots.keys().next().value);
  }

  async lookup(sessionID) {
    if (!this.lookups.has(sessionID)) {
      const pending = Promise.resolve()
        .then(() => this.client?.session?.get?.({ path: { id: sessionID } }))
        .then((result) => unwrap(result))
        .catch(() => null)
        .finally(() => this.lookups.delete(sessionID));
      this.lookups.set(sessionID, pending);
    }
    return this.lookups.get(sessionID);
  }

  async isRoot(sessionID, info = null) {
    if (!store.isSafeId(sessionID)) return false;
    if (info?.id === sessionID) this.rememberInfo(info);
    if (this.roots.has(sessionID)) return this.roots.get(sessionID);
    const fetched = await this.lookup(sessionID);
    if (!fetched?.id) return false;
    this.rememberInfo(fetched);
    return this.roots.get(sessionID) === true;
  }

  /** Root session for a tool call made in a root or subagent session. */
  async rootOf(sessionID) {
    let current = sessionID;
    for (let depth = 0; depth < 6 && store.isSafeId(current); depth += 1) {
      if (await this.isRoot(current)) return current;
      current = this.parents.get(current);
    }
    return "";
  }

  state(sessionID) {
    let state = this.sessions.get(sessionID);
    if (!state) {
      state = {
        sessionID,
        title: "",
        directory: this.directory,
        status: "unknown",
        task: "",
        agent: "",
        model: null,
        lastActivityMs: this.now(),
        turnHops: 0,
        wakePending: false,
        wakeHops: 0,
        wakeTimes: [],
        lastWriteMs: 0,
        writeTimer: null,
        written: "",
      };
      this.sessions.set(sessionID, state);
      while (this.sessions.size > MAX_TRACKED) this.forget(this.sessions.keys().next().value);
    }
    return state;
  }

  forget(sessionID) {
    const state = this.sessions.get(sessionID);
    if (state?.writeTimer) this.timers.clearTimeout(state.writeTimer);
    this.sessions.delete(sessionID);
    try {
      store.removePresence(this.root, sessionID);
    } catch (error) {
      warn("presence remove", error);
    }
  }

  // -------------------------------------------------------------------------
  // Presence
  // -------------------------------------------------------------------------

  repoInfo(directory) {
    const key = directory || this.directory;
    const cached = this.gitInfo.get(key);
    if (!key) return { worktree: "", branch: "", repo: "" };
    if (!cached || (!cached.pending && this.now() - cached.at > GIT_TTL_MS)) this.refreshGit(key, cached);
    return cached || { worktree: key, branch: "", repo: "" };
  }

  refreshGit(directory, previous) {
    const entry = { ...(previous || { worktree: directory, branch: "", repo: "" }), at: this.now(), pending: true };
    this.gitInfo.set(directory, entry);
    Promise.all([
      this.git(["-C", directory, "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"]).catch(() => null),
      previous?.repo ? Promise.resolve(null) : this.git(["-C", directory, "config", "--get", "remote.origin.url"]).catch(() => null),
    ]).then(([revParse, remote]) => {
      const [worktree = "", branch = ""] = String(revParse?.stdout || "").trim().split("\n");
      const next = {
        worktree: worktree || entry.worktree,
        branch: branch || entry.branch,
        repo: remote ? parseRepoSlug(remote.stdout) : entry.repo,
        at: this.now(),
        pending: false,
      };
      this.gitInfo.set(directory, next);
      if (next.branch !== entry.branch || next.repo !== entry.repo || next.worktree !== entry.worktree) {
        for (const state of this.sessions.values()) {
          if ((state.directory || this.directory) === directory) this.writePresence(state);
        }
      }
    });
  }

  record(state) {
    const git = this.repoInfo(state.directory);
    const refs = store.parseTitleRefs(state.title);
    const base = {
      v: store.BUS_VERSION,
      session_id: state.sessionID,
      title: String(state.title || "").slice(0, 200),
      pid: process.pid,
      start_token: this.processToken(),
      kind: this.kind,
      messageable: this.messageable,
      repo: git.repo,
      worktree: git.worktree,
      branch: git.branch,
      directory: state.directory || this.directory,
      issue: refs.issue,
      pr: refs.pr,
      status: state.status,
      current_task: state.task,
      last_activity_epoch: Math.floor(state.lastActivityMs / 1000),
    };
    return { ...base, handle: store.deriveHandle(base), updated_epoch: Math.floor(this.now() / 1000) };
  }

  processToken() {
    if (this.token === null) this.token = store.startToken(process.pid);
    return this.token;
  }

  writePresence(state) {
    if (this.disposed) return false;
    if (state.writeTimer) this.timers.clearTimeout(state.writeTimer);
    state.writeTimer = null;
    const record = this.record(state);
    if (!record.start_token) return false;
    try {
      store.writePresence(this.root, record);
      state.lastWriteMs = this.now();
      state.handle = record.handle;
      return true;
    } catch (error) {
      warn("presence write", error);
      return false;
    }
  }

  schedulePresence(state, urgent) {
    const wait = PRESENCE_THROTTLE_MS - (this.now() - state.lastWriteMs);
    if (urgent || wait <= 0) return this.writePresence(state);
    if (!state.writeTimer) {
      state.writeTimer = this.timers.setTimeout(() => this.writePresence(state), wait);
      state.writeTimer?.unref?.();
    }
    return false;
  }

  setStatus(state, status) {
    if (!status || state.status === status) return false;
    state.status = status;
    return true;
  }

  // -------------------------------------------------------------------------
  // Hooks
  // -------------------------------------------------------------------------

  async handleEvent(input) {
    const event = input?.event;
    const type = event?.type;
    if (!type) return;
    const sessionID = sessionIDFrom(event);
    if (!store.isSafeId(sessionID)) return;
    if (type === "session.deleted") {
      this.roots.set(sessionID, false);
      this.forget(sessionID);
      return;
    }
    const props = event.properties || {};
    const statusOf = STATUS_FROM_EVENT[type];
    const isSessionInfo = type === "session.created" || type === "session.updated";
    if (!statusOf && !isSessionInfo && !ACTIVITY_EVENTS.has(type)) return;
    const info = props.info?.id === sessionID ? props.info : null;
    if (!(await this.isRoot(sessionID, isSessionInfo ? info : null))) return;
    const state = this.state(sessionID);
    let urgent = isSessionInfo && state.written !== state.title;
    if (urgent) state.written = state.title;
    if (statusOf) urgent = this.setStatus(state, statusOf(props)) || urgent;
    // A new session is idle until a status event says otherwise.
    if (type === "session.created" && state.status === "unknown") urgent = this.setStatus(state, "idle") || urgent;
    if (type === "todo.updated") {
      const task = firstInProgressTodo(props.todos);
      urgent = urgent || task !== state.task;
      state.task = task;
    }
    if (!isSessionInfo) state.lastActivityMs = this.now();
    this.schedulePresence(state, urgent);
    if (state.status === "idle" && statusOf) await this.onIdle(sessionID);
  }

  async chatMessage(input, output) {
    const sessionID = input?.sessionID;
    if (!(await this.isRoot(sessionID))) return;
    const state = this.state(sessionID);
    if (typeof input.agent === "string" && input.agent) state.agent = input.agent;
    if (input.model?.providerID && input.model?.modelID) {
      state.model = { providerID: input.model.providerID, modelID: input.model.modelID };
    }
    // A turn started by a wake inherits the woken message's hop count.
    state.turnHops = state.wakePending ? state.wakeHops + 1 : 0;
    state.wakePending = false;
    state.lastActivityMs = this.now();
    this.schedulePresence(state, this.setStatus(state, "busy"));
    if (!this.messageable || !Array.isArray(output?.parts)) return;
    const claimed = this.claimPending(sessionID);
    if (claimed.length === 0) return;
    const base = output.parts.find((part) => part?.type === "text") || output.parts[0] || {};
    const messageID = output.message?.id || base.messageID;
    claimed.forEach((entry, index) => {
      const part = { type: "text", text: store.frameMessage(entry.message), synthetic: true, sessionID, messageID };
      if (base.id) part.id = `${base.id}zb${index}`;
      output.parts.push(part);
    });
  }

  toolAfter(input, output) {
    const sessionID = input?.sessionID;
    if (!this.messageable || this.roots.get(sessionID) !== true) return 0;
    if (input.tool === "aidevops_sessions" || typeof output?.output !== "string") return 0;
    const claimed = this.claimPending(sessionID);
    if (claimed.length === 0) return 0;
    output.output = `${output.output}\n\n${claimed.map((entry) => store.frameMessage(entry.message)).join("\n\n")}`;
    return claimed.length;
  }

  // -------------------------------------------------------------------------
  // Delivery
  // -------------------------------------------------------------------------

  claimPending(sessionID, limit = store.LIMITS.deliverPerBatch, entries = null) {
    const candidates = entries || store.pendingMessages(this.root, sessionID).slice(0, limit);
    return candidates.filter((entry) => store.claimMessage(this.root, sessionID, entry));
  }

  async onIdle(sessionID) {
    const state = this.state(sessionID);
    for (const subscription of store.takeIdleSubscriptions(this.root, sessionID)) {
      try {
        const what = [state.title && `title: ${state.title}`, state.task && `last task: ${state.task}`].filter(Boolean).join("; ");
        store.sendMessage(this.root, {
          from: this.fromFor(sessionID),
          to: subscription.subscriber,
          toHandle: subscription.handle,
          type: "idle-notice",
          text: `Session ${state.handle || sessionID} is now idle${what ? ` (${what})` : ""}.`,
        });
      } catch (error) {
        warn("idle notice", error);
      }
    }
    if (this.messageable) await this.deliverToIdle(sessionID, state);
  }

  async liveStatuses() {
    try {
      const statuses = unwrap(await this.client?.session?.status?.());
      return statuses && typeof statuses === "object" ? statuses : null;
    } catch {
      return null;
    }
  }

  async tick() {
    if (this.ticking || this.disposed) return;
    this.ticking = true;
    try {
      let statuses;
      for (const [sessionID, state] of this.sessions) {
        if (this.roots.get(sessionID) !== true) continue;
        const pending = store.pendingMessages(this.root, sessionID);
        if (pending.length === 0) continue;
        this.toastArrivals(state, pending);
        if (state.status === "unknown") {
          statuses = statuses === undefined ? await this.liveStatuses() : statuses;
          if (statuses) this.setStatus(state, statuses[sessionID]?.type === "busy" ? "busy" : "idle");
        }
        if (state.status === "idle") await this.deliverToIdle(sessionID, state, pending);
      }
    } catch (error) {
      warn("poll", error);
    } finally {
      this.ticking = false;
    }
  }

  async deliverToIdle(sessionID, state, pending = store.pendingMessages(this.root, sessionID)) {
    if (state.status !== "idle" || !pending.some((entry) => isWakeEligible(entry.message))) return false;
    const now = this.now();
    state.wakeTimes = state.wakeTimes.filter((time) => time > now - HOUR_MS);
    if (state.wakeTimes.length >= store.LIMITS.wakesPerHour) return false;
    if (typeof this.client?.session?.promptAsync !== "function") return false;
    const limit = store.LIMITS.deliverPerBatch;
    let batch = pending.slice(0, limit);
    if (!batch.some((entry) => isWakeEligible(entry.message))) {
      batch = pending.filter((entry) => isWakeEligible(entry.message)).slice(0, limit);
    }
    const claimed = this.claimPending(sessionID, limit, batch);
    if (claimed.length === 0) return false;
    state.status = "busy";
    state.wakePending = true;
    state.wakeHops = Math.max(...claimed.map((entry) => Number(entry.message.hops) || 0));
    state.wakeTimes.push(now);
    const body = {
      parts: [{ type: "text", text: claimed.map((entry) => store.frameMessage(entry.message)).join("\n\n"), synthetic: true }],
    };
    if (state.agent) body.agent = state.agent;
    if (state.model) body.model = state.model;
    let failure = null;
    try {
      failure = responseError(await this.client.session.promptAsync({ path: { id: sessionID }, body }));
    } catch (error) {
      failure = error;
    }
    if (failure) {
      for (const entry of claimed) store.unclaimMessage(this.root, sessionID, entry);
      state.wakePending = false;
      state.wakeTimes.pop();
      state.status = "unknown";
      warn("wake", failure);
      return false;
    }
    const first = claimed[0].message;
    await this.toast(`Woke ${state.handle || "session"}`, `${first.from?.handle || "peer"}: ${store.messagePreview(first, 100)}`);
    return true;
  }

  async toastArrivals(state, pending) {
    const fresh = pending.filter((entry) => !this.toasted.has(entry.message.id));
    if (fresh.length === 0) return;
    for (const entry of fresh) this.toasted.add(entry.message.id);
    while (this.toasted.size > MAX_TOASTED) this.toasted.delete(this.toasted.values().next().value);
    const latest = fresh[fresh.length - 1].message;
    const title = fresh.length > 1
      ? `${fresh.length} messages for ${state.handle || "this session"}`
      : `${latest.type === "ask" ? "Question" : "Message"} for ${state.handle || "this session"}`;
    await this.toast(title, `${latest.from?.handle || "peer"}: ${store.messagePreview(latest, 100)}`);
  }

  async toast(title, message) {
    try {
      await this.client?.tui?.showToast?.({ body: { title, message, variant: "info", duration: 8000 } });
    } catch {
      // Toasts are advisory; delivery does not depend on them.
    }
  }

  // -------------------------------------------------------------------------
  // Tool support
  // -------------------------------------------------------------------------

  fromFor(sessionID) {
    const state = this.state(sessionID);
    const record = this.record(state);
    return {
      session_id: sessionID,
      handle: record.handle,
      repo: record.repo,
      branch: record.branch,
      origin: "opencode",
    };
  }

  /** Sender identity from ToolContext, never from model-supplied arguments. */
  async sender(context) {
    const sessionID = await this.rootOf(context?.sessionID);
    if (!sessionID) throw new Error("aidevops_sessions could not resolve this session's root session");
    const state = this.state(sessionID);
    if (!state.lastWriteMs) this.writePresence(state);
    return { sessionID, from: this.fromFor(sessionID), hops: state.turnHops, record: this.record(state) };
  }
}

function warn(label, error) {
  let detail = error?.message;
  if (!detail) {
    try {
      detail = typeof error === "object" ? JSON.stringify(error) : String(error);
    } catch {
      detail = String(error);
    }
  }
  console.error(`[aidevops] session-bus ${label}: ${String(detail).slice(0, 300)}`);
}

export function createSessionBus(options = {}) {
  const bus = new SessionBus(options);
  if (options.start !== false) {
    bus.start();
    process.once("exit", () => bus.dispose());
  }
  return bus;
}
