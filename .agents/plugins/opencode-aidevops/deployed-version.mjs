// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Shared deployed-vs-loaded aidevops version helpers (GH#38862).
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const DEPLOYED_VERSION_FILE = join(homedir(), ".aidevops", "agents", "VERSION");

export function readVersion(path) {
  try {
    return readFileSync(path, "utf8").trim().split(/\r?\n/, 1)[0];
  } catch {
    return "";
  }
}

// Preserve the loaded version across updates; never substitute the new on-disk
// value for a missing startup value (an unknown version cannot prove drift).
export const LOADED_VERSION = readVersion(DEPLOYED_VERSION_FILE);

function parseVersion(value) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)/.exec(String(value || "").trim());
  return match ? match.slice(1, 4).map(Number) : null;
}

/** True only when `deployed` is strictly newer than `loaded` (both parseable). */
export function isDeployedNewer(loaded, deployed) {
  const a = parseVersion(loaded);
  const b = parseVersion(deployed);
  if (!a || !b) return false;
  for (let i = 0; i < 3; i += 1) {
    if (b[i] !== a[i]) return b[i] > a[i];
  }
  return false;
}

export function staleBundleMessage(loaded, deployed) {
  return `aidevops v${String(deployed).replace(/^v/, "")} was deployed after this session started `
    + `(running v${String(loaded).replace(/^v/, "")}); restart OpenCode to pick up fixes.`;
}

/**
 * Cheap per-turn check: one small file read at most every `intervalMs`,
 * one toast per plugin lifetime (= per session process).
 */
export function createVersionDriftNotice({
  client,
  isHeadless = () => false,
  loadedVersion = LOADED_VERSION,
  versionFile = DEPLOYED_VERSION_FILE,
  now = () => Date.now(),
  intervalMs = 5 * 60 * 1000,
  read = readVersion,
} = {}) {
  let lastCheck = 0;
  let emitted = false;
  return async function check() {
    if (emitted || !loadedVersion || isHeadless()) return false;
    const t = now();
    if (lastCheck && t - lastCheck < intervalMs) return false;
    lastCheck = t;
    const deployed = read(versionFile);
    if (!isDeployedNewer(loadedVersion, deployed)) return false;
    emitted = true;
    try {
      await client?.tui?.showToast?.({
        body: {
          title: "aidevops update deployed",
          message: staleBundleMessage(loadedVersion, deployed),
          variant: "warning",
          duration: 15000,
        },
      });
    } catch {
      // Notice is advisory; never break the tool hook.
    }
    return true;
  };
}
