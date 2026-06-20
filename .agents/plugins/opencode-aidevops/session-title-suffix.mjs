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
  if (process.env.AIDEVOPS_VERSION) return process.env.AIDEVOPS_VERSION.trim();

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
