// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { processStartIdentity } from "./process-start-identity.mjs";

/** Resolve runtime-provided identity; only supervisors may explicitly own themselves. */
export function runtimeOwner(sessionID, { allowSelfFallback = false } = {}) {
  let pid = allowSelfFallback ? String(process.pid) : "";
  let identity = allowSelfFallback ? processStartIdentity(process.pid) : "";
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
