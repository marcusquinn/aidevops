// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

const BLOCK_MESSAGE = "Playwriter (extension relay) is not Playwright. Use subagent_type playwright / @playwright unless the user writes 'Playwriter'.";

function selectsPlaywriter(tool, args) {
  return (tool === "task" && args?.subagent_type === "playwriter")
    || (tool === "aidevops_mcp" && args?.action === "connect" && args?.name === "playwriter");
}

export function assertPlaywriterExplicitlyRequested({ tool, args, latestUserText }) {
  if (!selectsPlaywriter(tool, args) || typeof latestUserText !== "string") return;
  if (!/playwriter/i.test(latestUserText)) throw new Error(BLOCK_MESSAGE);
}

function unwrap(response) {
  if (response?.error) throw new Error("Session lookup failed");
  return response?.data ?? response;
}

async function resolveRootID(client, sessionID, signal) {
  const seen = new Set();
  let id = sessionID;
  while (id && !seen.has(id) && seen.size < 32) {
    seen.add(id);
    const session = unwrap(await client.session.get({ path: { id }, signal }));
    if (!session?.id) return null;
    if (!session.parentID) return id;
    id = session.parentID;
  }
  return null;
}

function messageUserText(message) {
  if (!Array.isArray(message.parts)) return null;
  // Synthetic continuation/compaction turns cannot grant permission.
  const parts = message.parts.filter((part) => !part.synthetic && !part.ignored);
  if (message.parts.length && !parts.length) return undefined;
  return parts.filter((part) => part.type === "text" && typeof part.text === "string")
    .map((part) => part.text).join("\n");
}

function latestUserText(messages) {
  if (!Array.isArray(messages)) return null;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message?.info?.role === "user") {
      const text = messageUserText(message);
      if (text !== undefined) return text;
    }
  }
  return null;
}

async function lookupRootUserText(client, sessionID, signal) {
  const id = await resolveRootID(client, sessionID, signal);
  if (!id) return null;
  const history = unwrap(await client.session.messages({ path: { id }, signal }));
  return latestUserText(history);
}

// Use persisted root history, never a child's prompt or assistant text. Bound
// the complete lookup, including parent traversal, and fail open on API errors.
export async function resolveLatestUserText(client, sessionID, { timeoutMs = 3000 } = {}) {
  let timer;
  const controller = new AbortController();
  try {
    return await Promise.race([
      lookupRootUserText(client, sessionID, controller.signal),
      new Promise((resolve) => {
        timer = setTimeout(() => { controller.abort(); resolve(null); }, timeoutMs);
      }),
    ]);
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export function createPlaywriterSelectionGuard({ client, isHeadless, log, timeoutMs } = {}) {
  let loggedLookupFailure = false;
  return async (input, output) => {
    if (isHeadless?.() || !selectsPlaywriter(input.tool, output.args)) return;
    const latestUserText = await resolveLatestUserText(client, input.sessionID, { timeoutMs });
    if (latestUserText === null && !loggedLookupFailure) {
      loggedLookupFailure = true;
      log?.("WARN", "[playwriter-selection] Latest root user message unavailable; allowing Playwriter (fail open)");
    }
    assertPlaywriterExplicitlyRequested({ tool: input.tool, args: output.args, latestUserText });
  };
}
