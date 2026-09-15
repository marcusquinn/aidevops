// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { readFileSync } from "node:fs";

const PROFILE_DOCUMENT_URL = new URL("../../configs/opencode-runtime-profiles.json", import.meta.url);

function loadProfiles() {
  const document = JSON.parse(readFileSync(PROFILE_DOCUMENT_URL, "utf8"));
  if (document?.schema !== "aidevops-opencode-runtime-profiles/v1") {
    throw new Error("Unsupported OpenCode runtime profile schema");
  }
  if (!document.profiles?.v1 || !document.profiles?.v2) {
    throw new Error("OpenCode runtime profiles must define v1 and v2");
  }
  return Object.freeze({
    ...document,
    profiles: Object.freeze(Object.fromEntries(
      Object.entries(document.profiles).map(([id, profile]) => [id, Object.freeze({ id, ...profile })]),
    )),
  });
}

export const OPENCODE_RUNTIME_PROFILES = loadProfiles();

export function getOpenCodeRuntimeProfile(id = OPENCODE_RUNTIME_PROFILES.default) {
  const profile = OPENCODE_RUNTIME_PROFILES.profiles[id];
  if (!profile) throw new Error(`Unknown OpenCode runtime profile: ${id}`);
  return profile;
}

export function profileForOpenCodeVersion(version) {
  const major = Number.parseInt(String(version || "").match(/\d+/)?.[0] || "", 10);
  if (major === 1) return getOpenCodeRuntimeProfile("v1");
  if (major === 2) return getOpenCodeRuntimeProfile("v2");
  return getOpenCodeRuntimeProfile();
}

export function pluginEntryUrl(profile, agentsDir) {
  const root = String(agentsDir || "").replace(/\/$/, "");
  return `file://${root}/plugins/opencode-aidevops/${profile.pluginEntry}`;
}
