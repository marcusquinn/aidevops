// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { processStartIdentity } from "./process-start-identity.mjs";

/**
 * Resolve the runtime that serves this session.
 *
 * A session-bound inherited identity wins only with matching generation proof.
 * Otherwise the plugin's own process is the owner: OpenCode loads the plugin
 * inside the runtime that serves the session, and nothing exports
 * OPENCODE_PID/OPENCODE_PID_START_IDENTITY for that server process (GH#36430).
 * An empty pid means no generation proof exists; callers must report
 * runtime-owner-unresolved rather than invent an owner.
 */
let selfStartIdentity = "";

function ownStartIdentity() {
  // A process start time never changes; cache only a successful observation.
  if (!selfStartIdentity) selfStartIdentity = processStartIdentity(process.pid);
  return selfStartIdentity;
}

export function runtimeOwner(sessionID) {
  // #aidevops:trust-boundary — identities come from this process or the runtime
  // environment, never from tool arguments.
  const selfIdentity = ownStartIdentity();
  let pid = selfIdentity ? String(process.pid) : "";
  let identity = selfIdentity || "";
  const inheritedPID = process.env.OPENCODE_PID || "";
  const inheritedIdentity = process.env.OPENCODE_PID_START_IDENTITY || "";
  if (sessionID && sessionID === process.env.OPENCODE_SESSION_ID
      && /^[1-9][0-9]*$/.test(inheritedPID) && inheritedIdentity) {
    try {
      process.kill(Number(inheritedPID), 0);
      // #aidevops:trust-boundary — require the runtime's original generation proof.
      if (processStartIdentity(Number(inheritedPID)) === inheritedIdentity) {
        pid = inheritedPID;
        identity = inheritedIdentity;
      }
    } catch {
      // Unavailable or reused inherited identities never establish runtime ownership.
    }
  }
  return { pid, identity };
}
