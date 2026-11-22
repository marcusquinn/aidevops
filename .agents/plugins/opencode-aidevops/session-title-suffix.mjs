// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { emitTerminalTitle as defaultEmitTerminalTitle } from "./terminal-title.mjs";

const AIDEVOPS_TITLE_SUFFIX_RE = /\s+· AIDevOps \d+\.\d+\.\d+$/;
const DEFAULT_SESSION_TITLE_RE = /^New session - /;
const IMAGE_PLACEHOLDER_RE = /\[Image\s+\d+\]/gi;

function readIfExists(filepath) {
  try {
    if (existsSync(filepath)) {
      return readFileSync(filepath, "utf-8").trim();
    }
  } catch {
    // ignore unreadable version files
  }
  return "";
}

export function readAidevopsVersion(activeAgentsDir, runtimeAgentsDir = activeAgentsDir) {
  const activeVersion = activeAgentsDir ? readIfExists(join(activeAgentsDir, "VERSION")) : "";
  if (activeVersion) return activeVersion;
  if (process.env.AIDEVOPS_VERSION?.trim()) return process.env.AIDEVOPS_VERSION.trim();

  const candidates = runtimeAgentsDir
    ? [
        join(runtimeAgentsDir, "VERSION"),
        join(runtimeAgentsDir, "..", "VERSION"),
        join(runtimeAgentsDir, "..", "version"),
      ]
    : [];

  for (const candidate of candidates) {
    const version = readIfExists(candidate);
    if (version) return version;
  }

  return "";
}

export function sanitizeSessionTitle(title) {
  return String(title || "").replace(IMAGE_PLACEHOLDER_RE, " ").replace(/\s+/g, " ").trim();
}

// Paused (t18612): OpenCode 1.x session titles no longer carry
// `· AIDevOps <version>`; the v1-tui sidebar footer shows it instead, as
// OpenCode 2 does. Set AIDEVOPS_SESSION_TITLE_VERSION_SUFFIX=true to restore.
// Terminal titles built by v2-plugin/tui.mjs call withAidevopsTitleSuffix
// directly and are not affected.
export function isSessionTitleVersionSuffixEnabled(env = process.env) {
  const value = String(env.AIDEVOPS_SESSION_TITLE_VERSION_SUFFIX || "").trim().toLowerCase();
  return value === "true" || value === "1";
}

export function withAidevopsTitleSuffix(title, version) {
  const baseTitle = sanitizeSessionTitle(String(title || "").replace(AIDEVOPS_TITLE_SUFFIX_RE, ""));
  if (!version) return baseTitle;
  return `${baseTitle} · AIDevOps ${version}`;
}

// GH#37630: interactive root-session titles end with `· @<last 6 of the
// session ID>` so the session-bus address is visible in the OpenCode sidebar
// and the terminal tab. `@xxxxxx` resolves as a session-bus target. Order:
// `<title> · @xxxxxx[ · AIDevOps <version>]`.
// AIDEVOPS_SESSION_TITLE_ID=false disables it.
const SESSION_ADDRESS_TOKEN_RE = /\s+· @[a-z0-9]{6}(?![a-z0-9])/g;
const SESSION_ID_RE = /^ses_[A-Za-z0-9]{6,}$/;

export function sessionAddressToken(sessionID) {
  const id = String(sessionID || "");
  return SESSION_ID_RE.test(id) ? `@${id.slice(-6).toLowerCase()}` : "";
}

export function isSessionTitleAddressEnabled(env = process.env) {
  const value = String(env.AIDEVOPS_SESSION_TITLE_ID || "").trim().toLowerCase();
  return value !== "false" && value !== "0";
}

export function stripSessionAddressToken(title) {
  return String(title || "").replace(SESSION_ADDRESS_TOKEN_RE, "").trim();
}

export function stripSessionTitleDecorations(title) {
  return sanitizeSessionTitle(stripSessionAddressToken(title).replace(AIDEVOPS_TITLE_SUFFIX_RE, ""));
}

export function withSessionTitleDecorations(title, { version = "", sessionID = "" } = {}) {
  const baseTitle = stripSessionTitleDecorations(title);
  if (!baseTitle) return baseTitle;
  const token = sessionAddressToken(sessionID);
  return [baseTitle, token, version ? `AIDevOps ${version}` : ""].filter(Boolean).join(" · ");
}

function isDefaultSessionTitle(title) {
  const baseTitle = String(title || "").replace(AIDEVOPS_TITLE_SUFFIX_RE, "").trim();
  return DEFAULT_SESSION_TITLE_RE.test(baseTitle) || baseTitle === "New Session";
}

function shouldSynchronizeSessionTitle(update) {
  if (update.eventType !== "session.created" && update.eventType !== "session.updated") return false;
  if (!update.title) return false;
  return !isDefaultSessionTitle(update.title);
}

function getEventInfo(input) {
  return input?.event?.properties?.info || input?.properties?.info || input?.info || null;
}

function getEventSessionId(input, info) {
  const candidates = [input?.event?.properties?.sessionID, input?.properties?.sessionID, input?.sessionID, info?.id];
  return candidates.find(Boolean) || "";
}

function getSessionUpdate(input) {
  const eventType = input?.event?.type || input?.type || "";
  const info = getEventInfo(input);
  return {
    eventType,
    info,
    sessionID: getEventSessionId(input, info),
    title: info?.title || "",
  };
}

async function updateSessionTitle(client, sessionID, title) {
  try {
    await client.session.update({
      path: { id: sessionID },
      body: { title },
    });
  } catch (err) {
    await client.session.update({
      path: { sessionID },
      body: { title },
    });
  }
}

// Only interactive root sessions are addressed: subagent children are not on
// the session bus, and headless worker titles stay as dispatched.
function addressedSessionID(update, isHeadless, isAddressEnabled) {
  if (isHeadless() || !isAddressEnabled()) return "";
  if (update.info?.parentID) return "";
  return sessionAddressToken(update.sessionID) ? update.sessionID : "";
}

export function createSessionTitleSuffixHandler({
  activeAgentsDir,
  agentsDir = activeAgentsDir,
  client,
  emitTerminalTitle = defaultEmitTerminalTitle,
  isEnabled = isSessionTitleVersionSuffixEnabled,
  isAddressEnabled = isSessionTitleAddressEnabled,
  isHeadless = () => false,
}) {
  const inFlight = new Set();

  return async function sessionTitleSuffixHandler(input) {
    const update = getSessionUpdate(input);
    if (!shouldSynchronizeSessionTitle(update)) return;
    const sessionID = addressedSessionID(update, isHeadless, isAddressEnabled);
    if (!isEnabled() && !sessionID) {
      // Keep reasserting the session title to the terminal; never rewrite it.
      if (update.sessionID) emitTerminalTitle(update.title);
      return;
    }

    const version = isEnabled() ? readAidevopsVersion(activeAgentsDir || agentsDir, agentsDir) : "";
    const suffixedTitle = withSessionTitleDecorations(update.title, { version, sessionID });
    if (!update.sessionID || inFlight.has(update.sessionID)) return;
    if (suffixedTitle === update.title) {
      emitTerminalTitle(suffixedTitle);
      return;
    }
    if (typeof client?.session?.update !== "function") {
      // Without an update API the stored title stays as is; still reassert it.
      emitTerminalTitle(update.title);
      return;
    }

    inFlight.add(update.sessionID);
    try {
      await updateSessionTitle(client, update.sessionID, suffixedTitle);
      emitTerminalTitle(suffixedTitle);
    } finally {
      inFlight.delete(update.sessionID);
    }
  };
}
