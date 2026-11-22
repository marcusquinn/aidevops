// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: the sender identity a root session's messages carry. It is
// always taken from the runtime's own state and ToolContext, never from
// model-supplied arguments. The SessionBus methods fromFor() and sender()
// delegate here.

import * as store from "./session-bus-store.mjs";

/** The `from` block for messages a root session sends. */
export function senderIdentity(bus, sessionID, via = null) {
  const record = bus.record(bus.state(sessionID));
  return {
    session_id: sessionID,
    handle: record.handle,
    repo: record.repo,
    branch: record.branch,
    // #aidevops:trust-boundary t18898: a remote-hosted process sends as a chat origin, which never wakes.
    origin: bus.remote ? `chat:${bus.remote.interface}:${bus.remote.channel}` : "opencode",
    ...(via ? { via } : {}),
  };
}

/** Sender identity from ToolContext, never from model-supplied arguments. */
export async function resolveSender(bus, context) {
  const sessionID = await bus.tree.rootOf(context?.sessionID);
  if (!sessionID) throw new Error("aidevops_sessions could not resolve this session's root session");
  const state = bus.state(sessionID);
  if (!state.lastWriteMs) bus.writePresence(state);
  // A subagent acts as its root; the recipient sees the subagent as advisory `via`.
  const callerID = context?.sessionID;
  const via = callerID && callerID !== sessionID && store.isSafeId(callerID)
    ? { session_id: callerID, agent: String(context.agent || "").slice(0, 80) }
    : null;
  return { sessionID, from: senderIdentity(bus, sessionID, via), hops: state.turnHops, record: bus.record(state) };
}
