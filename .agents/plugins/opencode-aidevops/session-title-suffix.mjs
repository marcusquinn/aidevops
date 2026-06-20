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

function getAgentName(input) {
  const candidates = [
    input?.agent,
    input?.agentID,
    input?.agent_id,
    input?.agent?.id,
    input?.agent?.name,
  ];
  return candidates.find((value) => typeof value === "string" && value.trim()) || "";
}

export function isTitleAgentCompletion(input) {
  return getAgentName(input) === "title";
}

export function applyTitleAgentSuffix(input, output, agentsDir) {
  if (!output?.text || !isTitleAgentCompletion(input)) return;

  const version = readAidevopsVersion(agentsDir);
  output.text = withAidevopsTitleSuffix(output.text, version);
}

function getEventInfo(input) {
  return input?.event?.properties?.info || input?.properties?.info || input?.info || null;
}

function getEventSessionId(input, info) {
  return input?.event?.properties?.sessionID || input?.properties?.sessionID || input?.sessionID || info?.id || "";
}

export function createSessionTitleSuffixHandler({ agentsDir, client }) {
  const inFlight = new Set();

  return async function sessionTitleSuffixHandler(input) {
    const eventType = input?.event?.type || input?.type || "";
    if (eventType !== "session.updated") return;

    const info = getEventInfo(input);
    const title = info?.title || "";
    if (!title) return;

    const version = readAidevopsVersion(agentsDir);
    const suffixedTitle = withAidevopsTitleSuffix(title, version);
    if (suffixedTitle === title) return;

    const sessionID = getEventSessionId(input, info);
    if (!sessionID || inFlight.has(sessionID)) return;

    inFlight.add(sessionID);
    try {
      try {
        await client.session.update({
          path: { id: sessionID },
          body: { title: suffixedTitle },
        });
      } catch (err) {
        if (!client?.session?.update) throw err;
        await client.session.update({
          path: { sessionID },
          body: { title: suffixedTitle },
        });
      }
    } finally {
      inFlight.delete(sessionID);
    }
  };
}
