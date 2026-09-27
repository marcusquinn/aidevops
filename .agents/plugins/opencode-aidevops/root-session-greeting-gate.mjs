// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const GREETING_SKIP_LOG_LIMIT = 256;
const ROOT_LOOKUP_CACHE_LIMIT = 256;

/**
 * Greeting gate for OpenCode 1 and 2: every request of a root interactive
 * session keeps the greeting block, so the redistributed prefix stays stable.
 * Child sessions are skipped silently. Unexpected skips (a headless service
 * environment or a failed session lookup) are logged once per session because
 * they are otherwise invisible (GH#32498). A session's parent never changes,
 * so successful lookups are memoised; failures are retried on the next request.
 *
 * @param {object} deps
 * @param {(sessionID: string) => Promise<{ parentID?: string } | undefined>} deps.getSession
 * @param {() => boolean} [deps.isHeadless]
 * @param {(level: string, message: string) => void} [deps.log]
 * @returns {(input: { sessionID?: string }) => Promise<boolean>}
 */
export function createRootSessionGreetingGate({ getSession, isHeadless = () => false, log = () => {} } = {}) {
  const loggedSessions = new Set();
  const rootBySession = new Map();
  const skip = (sessionID, reason) => {
    if (!loggedSessions.has(sessionID)) {
      if (loggedSessions.size >= GREETING_SKIP_LOG_LIMIT) loggedSessions.clear();
      loggedSessions.add(sessionID);
      log("INFO", `Session greeting skipped for ${sessionID}: ${reason}`);
    }
    return false;
  };
  const resolveRoot = async (sessionID) => {
    if (!rootBySession.has(sessionID)) {
      const isRoot = !(await getSession(sessionID))?.parentID;
      if (rootBySession.size >= ROOT_LOOKUP_CACHE_LIMIT) rootBySession.clear();
      rootBySession.set(sessionID, isRoot);
    }
    return rootBySession.get(sessionID);
  };

  return async function shouldInjectRootSessionGreeting(input) {
    const sessionID = input?.sessionID;
    if (!sessionID) return false;
    if (isHeadless()) return skip(sessionID, "headless environment");
    if (typeof getSession !== "function") return skip(sessionID, "no session lookup");
    try {
      return await resolveRoot(sessionID);
    } catch (error) {
      return skip(sessionID, `session lookup failed (${error?.message || "unknown error"})`);
    }
  };
}

/**
 * Adapt the OpenCode 1 SDK client (`session.get({ path: { id } })`, which
 * reports failures as `{ error }` instead of throwing) to the gate's lookup.
 */
export function openCodeV1SessionLookup(client) {
  if (typeof client?.session?.get !== "function") return undefined;
  return async (sessionID) => {
    const response = await client.session.get({ path: { id: sessionID } });
    if (response?.error) throw new Error(response.error?.message || "session lookup error");
    return response?.data ?? response;
  };
}
