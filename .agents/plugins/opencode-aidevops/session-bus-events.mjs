// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: per-session state for the session-bus runtime and the
// OpenCode events and turns that change it. Pure functions: callers decide
// when to publish presence.

/**
 * OpenCode session status type -> bus status. `retry` is a turn still in
 * progress, so it counts as busy; unknown types return "" (no change).
 */
export function statusFromType(type) {
  const value = String(type || "").toLowerCase();
  if (value === "busy" || value === "retry") return "busy";
  return value === "idle" ? "idle" : "";
}

const STATUS_FROM_EVENT = {
  "session.idle": () => "idle",
  "permission.asked": () => "permission",
  "permission.updated": () => "permission",
  "permission.replied": () => "busy",
  "session.status": (props) => statusFromType(props.status?.type),
};

const SESSION_INFO_EVENTS = new Set(["session.created", "session.updated"]);
const ACTIVITY_EVENTS = new Set(["message.updated", "message.part.updated", "todo.updated"]);

export const isSessionInfoEvent = (type) => SESSION_INFO_EVENTS.has(type);
export const isStatusEvent = (type) => Object.hasOwn(STATUS_FROM_EVENT, type);
export const isTrackedEvent = (type) => isStatusEvent(type) || isSessionInfoEvent(type) || ACTIVITY_EVENTS.has(type);

export function newSessionState(sessionID, directory, now) {
  return {
    sessionID,
    title: "",
    directory,
    status: "unknown",
    task: "",
    agent: "",
    model: null,
    lastActivityMs: now,
    turnHops: 0,
    wakePending: false,
    wakeHops: 0,
    wakeTimes: [],
    wakeFailures: 0,
    wakeRetryAt: 0,
    lastWriteMs: 0,
    writeTimer: null,
    written: "",
  };
}

/** True when the status changed. */
export function setStatus(state, status) {
  if (!status || state.status === status) return false;
  state.status = status;
  return true;
}

function firstInProgressTodo(todos) {
  if (!Array.isArray(todos)) return "";
  const todo = todos.find((item) => item?.status === "in_progress");
  return String(todo?.content || "").replace(/\s+/g, " ").trim().slice(0, 160);
}

function updateTask(state, todos) {
  const task = firstInProgressTodo(todos);
  const changed = task !== state.task;
  state.task = task;
  return changed;
}

function updateWrittenTitle(state) {
  if (state.written === state.title) return false;
  state.written = state.title;
  return true;
}

/**
 * Apply one tracked event to a root session's state. Returns true when
 * presence should be written now rather than throttled.
 */
export function applyEvent(state, type, props, now) {
  const isSessionInfo = isSessionInfoEvent(type);
  let urgent = isSessionInfo && updateWrittenTitle(state);
  if (isStatusEvent(type)) urgent = setStatus(state, STATUS_FROM_EVENT[type](props)) || urgent;
  // A new session is idle until a status event says otherwise.
  if (type === "session.created" && state.status === "unknown") urgent = setStatus(state, "idle") || urgent;
  if (type === "todo.updated") urgent = updateTask(state, props.todos) || urgent;
  if (!isSessionInfo) state.lastActivityMs = now;
  return urgent;
}

/** Record a user turn's agent and model, so a wake can reuse them. */
export function rememberTurn(state, input, now) {
  if (typeof input.agent === "string" && input.agent) state.agent = input.agent;
  if (input.model?.providerID && input.model?.modelID) {
    state.model = { providerID: input.model.providerID, modelID: input.model.modelID };
  }
  // A turn started by a wake inherits the woken message's hop count.
  state.turnHops = state.wakePending ? state.wakeHops + 1 : 0;
  state.wakePending = false;
  state.lastActivityMs = now;
}
