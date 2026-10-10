// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import { isAbsolute } from "node:path";

// Tools resolve through the inherited PATH only: keep its order, drop empty or
// relative entries and duplicates. No distro-specific roots (FHS, Homebrew or
// Nix) are injected; user-managed toolchains must win over system copies.
export function runtimePath(path = "") {
  return [...new Set(path.split(":").filter((entry) => entry && isAbsolute(entry)))].join(":");
}

// Plugin-native subprocesses (including MCP launchers) see the same PATH as
// shell tools. No login-shell evaluation or desktop/system config mutation.
process.env.PATH = runtimePath(process.env.PATH);
