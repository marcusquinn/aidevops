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

// Use the persisted root history, never a child's delegation prompt or an
// assistant message. Bound the complete lookup, including parent traversal.
export async function resolveLatestUserText(client, sessionID, { timeoutMs = 3000 } = {}) {
  let timer;
  const controller = new AbortController();
  const lookup = async () => {
    const seen = new Set();
    let id = sessionID;
    while (id && !seen.has(id) && seen.size < 32) {
      seen.add(id);
      const response = await client.session.get({ path: { id }, signal: controller.signal });
      if (response?.error) return null;
      const session = response?.data ?? response;
      if (!session?.id) return null;
      if (session.parentID) {
        id = session.parentID;
        continue;
      }
      const history = await client.session.messages({ path: { id }, signal: controller.signal });
      if (history?.error) return null;
      const messages = history?.data ?? history;
      if (!Array.isArray(messages)) return null;
      for (let index = messages.length - 1; index >= 0; index -= 1) {
        const message = messages[index];
        if (message?.info?.role !== "user") continue;
        if (!Array.isArray(message.parts)) return null;
        // Synthetic continuation/compaction turns cannot grant permission.
        const parts = message.parts.filter((part) => !part.synthetic && !part.ignored);
        if (message.parts.length && !parts.length) continue;
        return parts.filter((part) => part.type === "text" && typeof part.text === "string")
          .map((part) => part.text).join("\n");
      }
      return null;
    }
    return null;
  };
  try {
    return await Promise.race([
      lookup(),
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
