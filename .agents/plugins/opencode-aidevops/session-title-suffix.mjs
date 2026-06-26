// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, readFileSync } from "fs";
import { join } from "path";

const AIDEVOPS_TITLE_SUFFIX_RE = /\s+· AIDevOps \d+\.\d+\.\d+$/;
const DEFAULT_SESSION_TITLE_RE = /^New session - /;

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

export function readAidevopsVersion(agentsDir) {
  const candidates = [
    join(agentsDir, "VERSION"),
    join(agentsDir, "..", "VERSION"),
    join(agentsDir, "..", "version"),
  ];

  for (const candidate of candidates) {
    const version = readIfExists(candidate);
    if (version) return version;
  }

  return "";
}

export function withAidevopsTitleSuffix(title, version) {
  const baseTitle = String(title || "").replace(AIDEVOPS_TITLE_SUFFIX_RE, "");
  if (!version) return baseTitle;
  return `${baseTitle} · AIDevOps ${version}`;
}

function isDefaultSessionTitle(title) {
  const baseTitle = String(title || "").replace(AIDEVOPS_TITLE_SUFFIX_RE, "").trim();
  return DEFAULT_SESSION_TITLE_RE.test(baseTitle) || baseTitle === "New Session";
}

function shouldSuffixSessionTitle(update) {
  if (update.eventType !== "session.updated") return false;
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

export function createSessionTitleSuffixHandler({ agentsDir, client }) {
  const inFlight = new Set();

  return async function sessionTitleSuffixHandler(input) {
    if (typeof client?.session?.update !== "function") return;

    const update = getSessionUpdate(input);
    if (!shouldSuffixSessionTitle(update)) return;

    const version = readAidevopsVersion(agentsDir);
    const suffixedTitle = withAidevopsTitleSuffix(update.title, version);
    if (suffixedTitle === update.title) return;

    if (!update.sessionID || inFlight.has(update.sessionID)) return;

    inFlight.add(update.sessionID);
    try {
      await updateSessionTitle(client, update.sessionID, suffixedTitle);
    } finally {
      inFlight.delete(update.sessionID);
    }
  };
}
