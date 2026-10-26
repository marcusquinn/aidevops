// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#35697: resolve the pinned Playwriter package before the authenticated
// relay proof starts. The proof window is short (seconds) because a relay that
// is already installed starts quickly. A cold `npx` download inside that window
// was stopped together with the guardian, so the cache never warmed and every
// later activation failed the same way.

import { spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, delimiter, dirname, isAbsolute, join } from "node:path";
import { POSIX_GROUPS, hasExited, pause } from "./playwriter-relay-lifecycle.mjs";

// How long one activation waits for a cold download before reporting it. This
// plus the 5s relay proof stays inside the 30s MCP activation wait
// (mcp-activation-tool.mjs connectTimeoutMs). The warm process is detached, so
// it keeps downloading after this launcher exits.
export const PACKAGE_WARM_WAIT_MS = 20_000;

function npmCacheRoot(environment) {
  return environment.npm_config_cache || environment.NPM_CONFIG_CACHE || join(homedir(), ".npm");
}

function installedVersion(entryDirectory, name) {
  try {
    const manifestPath = join(entryDirectory, "node_modules", name, "package.json");
    return JSON.parse(readFileSync(manifestPath, "utf8"))?.version ?? null;
  } catch {
    return null;
  }
}

// npx runs a matching global install without touching its cache. npm's default
// prefix is the parent of the (unresolved) bin directory holding the runner,
// e.g. /opt/homebrew/bin/npx -> /opt/homebrew. A miss here only costs one fast
// `--version` warm, so these candidates are a heuristic, not a contract.
function globalPrefixes(runner, environment) {
  const explicit = environment.npm_config_prefix || environment.NPM_CONFIG_PREFIX;
  if (explicit) return [explicit];
  const prefixes = [];
  if (isAbsolute(runner)) {
    prefixes.push(dirname(dirname(runner)));
  } else {
    for (const directory of (environment.PATH || "").split(delimiter)) {
      if (directory && existsSync(join(directory, runner))) {
        prefixes.push(dirname(directory));
        break;
      }
    }
  }
  prefixes.push(dirname(dirname(process.execPath)));
  return prefixes;
}

/**
 * Report whether npx can run the pinned package without downloading it.
 * @param {string[]} command reviewed package-runner command
 * @param {{name: string, version: string}} pin
 * @returns {boolean|null} null when the runner is not npx (cache layout unknown)
 */
export function pinnedPackageCached(command, pin, environment = process.env) {
  if (basename(command[0]) !== "npx") return null;
  if (globalPrefixes(command[0], environment)
    .some((prefix) => installedVersion(join(prefix, "lib"), pin.name) === pin.version)) return true;
  const npxRoot = join(npmCacheRoot(environment), "_npx");
  let entries = [];
  try {
    entries = readdirSync(npxRoot);
  } catch {
    return false;
  }
  return entries.some((entry) => installedVersion(join(npxRoot, entry), pin.name) === pin.version);
}

/**
 * Start a bounded `<runner> <package> --version` in its own process group.
 * It is detached and unreferenced on purpose: if the MCP host stops this
 * launcher, the download still completes and the next activation succeeds.
 * The relay token is never passed to it.
 */
export function startPackageWarm(command, environment, spawnImpl = spawn) {
  const warmEnvironment = { ...environment };
  delete warmEnvironment.PLAYWRITER_TOKEN;
  const warm = spawnImpl(command[0], [...command.slice(1), "--version"], {
    env: warmEnvironment,
    shell: false,
    detached: POSIX_GROUPS,
    stdio: "ignore",
  });
  warm.spawnFailed = false;
  warm.once("error", () => { warm.spawnFailed = true; });
  warm.unref();
  return warm;
}

/** Operator-facing warm command for the configured runner (no secrets). */
export function warmCommandHint(command) {
  const runner = basename(command[0]);
  const args = runner === "npx" && !command.includes("-y") ? ["-y", ...command.slice(1)] : command.slice(1);
  return ["PLAYWRITER_TELEMETRY=0", "DO_NOT_TRACK=1", runner, ...args, "--version"].join(" ");
}

/**
 * Only a positive npx cache hit skips the warm. Other runners (bun x) have no
 * cheap cache probe, and their warm is sub-second once cached.
 * @returns {Promise<"cached"|"resolved"|"pending"|"failed">}
 */
export async function ensurePackageResolved(command, pin, environment, {
  waitMs = PACKAGE_WARM_WAIT_MS,
  shouldStop = () => false,
  spawnImpl = spawn,
} = {}) {
  if (pinnedPackageCached(command, pin, environment) === true) return "cached";
  const warm = startPackageWarm(command, environment, spawnImpl);
  const deadline = Date.now() + waitMs;
  while (!hasExited(warm) && !warm.spawnFailed && !shouldStop() && Date.now() < deadline) {
    await pause(100);
  }
  if (warm.spawnFailed) return "failed";
  if (!hasExited(warm)) return "pending";
  return warm.exitCode === 0 ? "resolved" : "failed";
}

/**
 * Throw an operator-facing relay error unless the pinned package resolved.
 * @param {string} errorPrefix prefix shared with the caller's other errors
 */
export async function requirePackageResolved(command, pin, environment, errorPrefix, options = {}) {
  const resolution = await ensurePackageResolved(command, pin, environment, options);
  if (resolution === "cached" || resolution === "resolved") return resolution;
  const packageSpec = `${pin.name}@${pin.version}`;
  const detail = resolution === "pending"
    ? `${packageSpec} is still downloading into the package cache in the background; reconnect @playwriter shortly, or`
    : `could not resolve ${packageSpec};`;
  throw new Error(`${errorPrefix}relay-package-not-cached: ${detail} warm it with: ${warmCommandHint(command)}`);
}
