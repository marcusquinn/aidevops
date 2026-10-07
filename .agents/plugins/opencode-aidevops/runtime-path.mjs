// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import { existsSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { join } from "node:path";

// Append stable profiles, preserving framework guards and project tool versions.
export function runtimePath(path = "", home = homedir(), account = userInfo().username) {
  const profiles = [
    join(home, ".nix-profile/bin"),
    join(home, ".local/state/nix/profile/bin"),
    join("/etc/profiles/per-user", account, "bin"),
    "/run/wrappers/bin",
    "/run/current-system/sw/bin",
  ].filter((directory) => existsSync(directory));
  return [...new Set([...path.split(":"), ...profiles].filter(Boolean))].join(":");
}

// Plugin-native subprocesses (including MCP launchers) need the same profiles
// as shell tools. No login-shell evaluation or desktop/system config mutation.
process.env.PATH = runtimePath(process.env.PATH);
