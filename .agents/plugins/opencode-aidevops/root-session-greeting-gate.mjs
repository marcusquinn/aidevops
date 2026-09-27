// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const GREETING_SKIP_LOG_LIMIT = 256;

/**
 * OpenCode 2 greeting gate: every request of a root interactive session keeps
 * the greeting block, so the redistributed prefix stays stable. Child sessions
 * are skipped silently. Unexpected skips (a headless service environment or a
 * failed session lookup) are logged once per session because they are
 * otherwise invisible (GH#32498).
 *
 * @param {object} deps
 * @param {(sessionID: string) => Promise<{ parentID?: string } | undefined>} deps.getSession
 * @param {() => boolean} [deps.isHeadless]
 * @param {(level: string, message: string) => void} [deps.log]
 * @returns {(input: { sessionID?: string }) => Promise<boolean>}
 */
export function createRootSessionGreetingGate({ getSession, isHeadless = () => false, log = () => {} } = {}) {
  const loggedSessions = new Set();
  const skip = (sessionID, reason) => {
    if (!loggedSessions.has(sessionID)) {
      if (loggedSessions.size >= GREETING_SKIP_LOG_LIMIT) loggedSessions.clear();
      loggedSessions.add(sessionID);
      log("INFO", `Session greeting skipped for ${sessionID}: ${reason}`);
    }
    return false;
  };

  return async function shouldInjectRootSessionGreeting(input) {
    const sessionID = input?.sessionID;
    if (!sessionID) return false;
    if (isHeadless()) return skip(sessionID, "headless environment");
    if (typeof getSession !== "function") return skip(sessionID, "no session lookup");
    try {
      const session = await getSession(sessionID);
      return !session?.parentID;
    } catch (error) {
      return skip(sessionID, `session lookup failed (${error?.message || "unknown error"})`);
    }
  };
}
