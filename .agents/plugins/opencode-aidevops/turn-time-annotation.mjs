// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

const PREFIX = "[turn received ";
const ANNOTATION_RE = /^\[turn received \d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z\]$/;
const LOOKUP_TIMEOUT_MS = 2000;

/** Bounded session lookup: the SDK disables request timeouts, so race a timer. */
async function lookupSession(client, sessionID) {
  const controller = new AbortController();
  let timer;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => {
      controller.abort();
      resolve(undefined);
    }, LOOKUP_TIMEOUT_MS);
  });
  try {
    const request = Promise.resolve(
      client?.session?.get?.({ path: { id: sessionID }, signal: controller.signal }),
    );
    const response = await Promise.race([request, timeout]);
    return response?.data ?? response;
  } finally {
    clearTimeout(timer);
  }
}

function annotateMessage(message) {
  const created = message?.info?.time?.created;
  if (message?.info?.role !== "user" || !Number.isFinite(created) || !Array.isArray(message.parts)) return;
  // Compaction anchors are host-generated, not interactive user turns.
  if (message.parts.some((part) => part?.type === "compaction")) return;
  const first = message.parts[0];
  if (first?.type === "text" && first.synthetic === true && ANNOTATION_RE.test(first.text ?? "")) return;
  const date = new Date(created);
  if (!Number.isFinite(date.getTime())) return;
  const text = `${PREFIX}${date.toISOString().slice(0, 16)}Z]`;
  message.parts = [{ type: "text", text, synthetic: true }, ...message.parts];
}

/** Keep annotation failures from blocking the composed message transform. */
export async function annotateTurnTimesSafely(input, output, options, qualityLog) {
  try {
    await annotateTurnTimes(input, output, options);
  } catch (err) {
    qualityLog("WARN", `[turn-time-annotation] Unexpected error: ${err?.message ?? err}`);
  }
}

/** Annotate only verified interactive root requests; never change stored history.
 * The transform input is empty on v1, so recover the session from message info.
 * Use message creation time, not wall-clock time, to preserve prompt caching.
 */
export async function annotateTurnTimes(input, output, { client, isHeadless = () => false } = {}) {
  if (isHeadless() || process.env.AIDEVOPS_TURN_TIME_ANNOTATION === "0") return;
  const messages = output?.messages;
  if (!Array.isArray(messages) || messages.length === 0) return;
  const sessionID = input?.sessionID || messages.find((message) => message?.info?.sessionID)?.info.sessionID;
  if (!sessionID) return;
  const session = await lookupSession(client, sessionID);
  // Missing metadata is not proof of a root session: skip rather than annotate children.
  if (session?.id !== sessionID || session.parentID) return;

  for (const message of messages) annotateMessage(message);
}
