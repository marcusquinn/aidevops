// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

const PREFIX = "[turn received ";

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
  const response = await client?.session?.get?.({ path: { id: sessionID } });
  const session = response?.data ?? response;
  // Missing metadata is not proof of a root session: skip rather than annotate children.
  if (session?.id !== sessionID || session.parentID) return;

  for (const message of messages) {
    const created = message?.info?.time?.created;
    if (message?.info?.role !== "user" || !Number.isFinite(created) || !Array.isArray(message.parts)) continue;
    if (message.parts.some((part) => part?.type === "text" && part.text?.startsWith(PREFIX))) continue;
    const date = new Date(created);
    if (!Number.isFinite(date.getTime())) continue;
    const text = `${PREFIX}${date.toISOString().slice(0, 16)}Z]`;
    message.parts = [{ type: "text", text, synthetic: true }, ...message.parts];
  }
}
