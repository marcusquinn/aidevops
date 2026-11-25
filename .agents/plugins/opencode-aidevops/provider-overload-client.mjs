// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// t19362 / GH#40283: OpenCode SDK calls for provider-overload-retry.mjs.
// Each call fails closed and never logs message content.

import { continuationText, requestIdentity, sessionHash } from "./provider-overload-policy.mjs";

const RECENT_MESSAGE_LIMIT = 100;
const TOAST_DURATION_MS = 15_000;

function unwrap(response) {
  return response?.data ?? response;
}

function responseError(response) {
  return response?.error || response?.data?.error || null;
}

/** The session's parent ID ("" for a root session), or null when unknown. */
export async function sessionParentID(client, sessionID) {
  try {
    const info = unwrap(await client?.session?.get?.({ path: { id: sessionID } }));
    return info?.id ? String(info.parentID || "") : null;
  } catch {
    return null;
  }
}

/** Live status type ("idle", "busy", "retry"), or "" when unavailable. */
export async function liveStatus(client, directory, sessionID) {
  if (typeof client?.session?.status !== "function") return "";
  try {
    const response = await client.session.status(directory ? { query: { directory } } : {});
    const statuses = unwrap(response);
    if (responseError(response) || !statuses || typeof statuses !== "object") return "";
    // The status map lists only non-idle sessions.
    return String(statuses[sessionID]?.type || "idle").toLowerCase();
  } catch {
    return "";
  }
}

/** Agent, model and variant of the latest stored user message, or null. */
export async function lastRequest(client, sessionID) {
  if (typeof client?.session?.messages !== "function") return null;
  try {
    const messages = unwrap(await client.session.messages({
      path: { id: sessionID },
      query: { limit: RECENT_MESSAGE_LIMIT },
    }));
    if (!Array.isArray(messages)) return null;
    return requestIdentity(messages.findLast((message) => message?.info?.role === "user")?.info);
  } catch {
    return null;
  }
}

function continuationBody(request, attempt, maxAttempts) {
  const body = { parts: [{ type: "text", text: continuationText(attempt, maxAttempts), synthetic: true }] };
  if (!request) return body;
  body.model = { providerID: request.providerID, modelID: request.modelID };
  if (request.agent) body.agent = request.agent;
  if (request.variant) body.variant = request.variant;
  return body;
}

export async function showToast(client, body, log) {
  if (typeof client?.tui?.showToast !== "function") return;
  try {
    await client.tui.showToast({ body: { ...body, duration: TOAST_DURATION_MS } });
  } catch (error) {
    log("WARN", `[overload-retry] toast failed: ${error?.name || "Error"}`);
  }
}

/** Send the synthetic continuation; true once OpenCode accepts it. */
export async function sendContinuation({ client, log }, sessionID, request, attempt, maxAttempts) {
  const hash = sessionHash(sessionID);
  if (typeof client?.session?.promptAsync !== "function") {
    log("WARN", `[overload-retry] skipped reason=prompt_unavailable session=${hash}`);
    return false;
  }
  try {
    const response = await client.session.promptAsync({
      path: { id: sessionID },
      body: continuationBody(request, attempt, maxAttempts),
    });
    if (responseError(response)) throw new Error("prompt rejected");
  } catch (error) {
    log("WARN", `[overload-retry] prompt failed attempt=${attempt}/${maxAttempts} session=${hash}: ${error?.name || "Error"}`);
    await showToast(client, {
      title: "Automatic retry failed",
      message: "The provider-overload retry could not be sent. Send a message to continue.",
      variant: "error",
    }, log);
    return false;
  }
  log("INFO", `[overload-retry] resumed attempt=${attempt}/${maxAttempts} session=${hash}`);
  return true;
}
