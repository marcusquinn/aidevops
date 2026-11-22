// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: root/subagent session tree for the session-bus runtime.
// Only root sessions publish presence and receive messages; a subagent's tool
// calls act for its root session.

import { isSafeId } from "./session-bus-store.mjs";
import { unwrap } from "./session-bus-client.mjs";

const MAX_KNOWN = 256;
const MAX_DEPTH = 6;

export class SessionTree {
  constructor({ client, onRootInfo = () => {} } = {}) {
    this.client = client;
    this.onRootInfo = onRootInfo;
    this.roots = new Map();
    this.parents = new Map();
    this.lookups = new Map();
  }

  remember(info) {
    if (!isSafeId(info?.id)) return;
    this.roots.set(info.id, !info.parentID);
    if (info.parentID) this.parents.set(info.id, info.parentID);
    else this.onRootInfo(info);
    while (this.roots.size > MAX_KNOWN) this.roots.delete(this.roots.keys().next().value);
  }

  markDeleted(sessionID) {
    this.roots.set(sessionID, false);
  }

  /** Known root without a lookup, for synchronous hooks. */
  isKnownRoot(sessionID) {
    return this.roots.get(sessionID) === true;
  }

  lookup(sessionID) {
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
    if (!isSafeId(sessionID)) return false;
    if (info?.id === sessionID) this.remember(info);
    if (this.roots.has(sessionID)) return this.roots.get(sessionID);
    const fetched = await this.lookup(sessionID);
    if (fetched?.id) this.remember(fetched);
    return this.isKnownRoot(sessionID);
  }

  /** Root session for a tool call made in a root or subagent session. */
  async rootOf(sessionID) {
    let current = sessionID;
    for (let depth = 0; depth < MAX_DEPTH && isSafeId(current); depth += 1) {
      if (await this.isRoot(current)) return current;
      current = this.parents.get(current);
    }
    return "";
  }
}
