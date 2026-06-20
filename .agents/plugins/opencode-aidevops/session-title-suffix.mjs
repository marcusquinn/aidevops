// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, readFileSync } from "fs";
import { join } from "path";

const AIDEVOPS_TITLE_SUFFIX_RE = /\s+· AIDevOps \d+\.\d+\.\d+$/;

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

function getEventInfo(input) {
  return input?.event?.properties?.info || input?.properties?.info || input?.info || null;
}

function getEventSessionId(input, info) {
  return input?.event?.properties?.sessionID || input?.properties?.sessionID || input?.sessionID || info?.id || "";
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

    const { eventType, sessionID, title } = getSessionUpdate(input);
    if (eventType !== "session.updated") return;
    if (!title) return;

    const version = readAidevopsVersion(agentsDir);
    const suffixedTitle = withAidevopsTitleSuffix(title, version);
    if (suffixedTitle === title) return;

    if (!sessionID || inFlight.has(sessionID)) return;

    inFlight.add(sessionID);
    try {
      await updateSessionTitle(client, sessionID, suffixedTitle);
    } finally {
      inFlight.delete(sessionID);
    }
  };
}
