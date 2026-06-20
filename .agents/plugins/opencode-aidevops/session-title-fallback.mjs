// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { readAidevopsVersion, withAidevopsTitleSuffix } from "./session-title-suffix.mjs";

const AIDEVOPS_TITLE_SUFFIX_RE = /\s+· AIDevOps \d+\.\d+\.\d+$/;
const DEFAULT_SESSION_TITLE_RE = /^New session - /;
const URL_RE = /https?:\/\/\S+/g;
const TITLE_MAX_LENGTH = 72;

export function isDefaultSessionTitle(title) {
  const baseTitle = String(title || "").replace(AIDEVOPS_TITLE_SUFFIX_RE, "").trim();
  return DEFAULT_SESSION_TITLE_RE.test(baseTitle) || baseTitle === "New Session";
}

function firstPromptLine(prompt) {
  return (
    String(prompt || "")
      .replace(URL_RE, " ")
      .split("\n")
      .map((value) => value.trim())
      .find((value) => value.length > 0) || "OpenCode session"
  );
}

function cleanedTitleLine(line) {
  const cleaned = line
    .replace(/^(i'd like to|i would like to|please|can you|could you)\s+/i, "")
    .replace(/[.?!:;,]+$/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return cleaned || "OpenCode session";
}

function titleCaseFirstWord(text) {
  return text.replace(/^([a-z])/, (letter) => letter.toUpperCase());
}

function trimTitle(text) {
  return text.length <= TITLE_MAX_LENGTH ? text : `${text.slice(0, TITLE_MAX_LENGTH - 1).trimEnd()}…`;
}

export function deriveFallbackTitleFromPrompt(prompt) {
  return trimTitle(titleCaseFirstWord(cleanedTitleLine(firstPromptLine(prompt))));
}

function getEventType(input) {
  return input?.event?.type || input?.type || "";
}

function getProperties(input) {
  return input?.event?.properties || input?.properties || input || {};
}

function getInfo(input) {
  return getProperties(input).info || input?.info || null;
}

function getSessionId(input, info) {
  const properties = getProperties(input);
  if (properties.sessionID) return properties.sessionID;
  if (input?.sessionID) return input.sessionID;
  if (info?.sessionID) return info.sessionID;
  return info?.id || "";
}

function getPart(input) {
  return getProperties(input).part || null;
}

function isUserMessageEvent(input) {
  const info = getInfo(input);
  if (!getEventType(input).startsWith("message.updated")) return false;
  return info?.role === "user";
}

function isTextPartEvent(input) {
  const part = getPart(input);
  if (!getEventType(input).startsWith("message.part.updated")) return false;
  if (part?.type !== "text") return false;
  return Boolean(part.text?.trim());
}

async function updateSessionTitle(client, sessionID, title) {
  try {
    await client.session.update({ path: { id: sessionID }, body: { title } });
  } catch {
    await client.session.update({ path: { sessionID }, body: { title } });
  }
}

function rememberTitle(input, sessionTitles) {
  const info = getInfo(input);
  const eventType = getEventType(input);
  if (!eventType.startsWith("session.")) return;
  if (!info?.title) return;
  sessionTitles.set(getSessionId(input, info), info.title);
}

function rememberUserMessage(input, userMessagesBySession) {
  const info = getInfo(input);
  const sessionID = getSessionId(input, info);
  const messages = userMessagesBySession.get(sessionID) || new Set();
  if (isUserMessageEvent(input) && info?.id) messages.add(info.id);
  if (messages.size > 0) userMessagesBySession.set(sessionID, messages);
}

function shouldApplyFallback(input, sessionTitles, userMessagesBySession, fallbackDone) {
  const part = getPart(input);
  const sessionID = part?.sessionID || getSessionId(input, null);
  const userMessages = userMessagesBySession.get(sessionID);
  const currentTitle = sessionTitles.get(sessionID) || "";
  if (!isTextPartEvent(input)) return false;
  if (!userMessages?.has(part?.messageID)) return false;
  if (fallbackDone.has(sessionID)) return false;
  return isDefaultSessionTitle(currentTitle);
}

export function createSessionTitleFallbackHandler({ agentsDir, client }) {
  const sessionTitles = new Map();
  const userMessagesBySession = new Map();
  const fallbackDone = new Set();

  return async function sessionTitleFallbackHandler(input) {
    if (typeof client?.session?.update !== "function") return;
    rememberTitle(input, sessionTitles);
    rememberUserMessage(input, userMessagesBySession);
    if (!shouldApplyFallback(input, sessionTitles, userMessagesBySession, fallbackDone)) return;

    const part = getPart(input);
    const sessionID = part.sessionID || getSessionId(input, null);
    const version = readAidevopsVersion(agentsDir);
    const title = withAidevopsTitleSuffix(deriveFallbackTitleFromPrompt(part.text), version);
    await updateSessionTitle(client, sessionID, title);
    sessionTitles.set(sessionID, title);
    fallbackDone.add(sessionID);
  };
}
