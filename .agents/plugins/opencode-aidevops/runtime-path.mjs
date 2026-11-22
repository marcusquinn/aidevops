// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import { accessSync, constants, mkdirSync, mkdtempSync, rmSync, statSync, symlinkSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

// Tools resolve through the inherited PATH only: keep its order, drop empty or
// relative entries and duplicates. No distro-specific roots (FHS, Homebrew or
// Nix) are injected; user-managed toolchains must win over system copies.
export function runtimePath(path = "") {
  return [...new Set(path.split(":").filter((entry) => entry && isAbsolute(entry)))].join(":");
}

function aidevopsExecutable(path) {
  for (const entry of runtimePath(path).split(":")) {
    if (!entry || /[\r\n]/.test(entry)) continue;
    const executable = join(entry, "aidevops");
    try {
      if (!statSync(executable).isFile()) continue;
      accessSync(executable, constants.X_OK);
      return executable;
    } catch {
      // Missing, dangling or non-executable installations are not capabilities.
    }
  }
  return "";
}

const cliProjections = new Map();
process.once("exit", () => {
  for (const directory of cliProjections.values()) {
    try { rmSync(directory, { recursive: true, force: true }); } catch { /* best effort */ }
  }
});

// #aidevops:trust-boundary — project one executable, never its sibling commands
// or the supervisor's entire PATH/environment. Call only for ordinary worker
// tools, not explicitly sanitized application environments. Existing tool PATH
// commands keep precedence. No shell evaluation or installation is performed.
export function managedCliPath(toolPath, inheritedPath = process.env.PATH || "") {
  if (aidevopsExecutable(toolPath)) return "";
  const executable = aidevopsExecutable(inheritedPath);
  if (!executable) return "";
  const tempRoot = process.env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  if (!isAbsolute(tempRoot) || /[:\r\n]/.test(tempRoot)) return "";
  const key = `${tempRoot}\n${executable}`;
  const cached = cliProjections.get(key);
  if (cached && aidevopsExecutable(cached)) return cached;
  return createCliProjection(tempRoot, executable, key);
}

function createCliProjection(tempRoot, executable, key) {
  let directory;
  try {
    mkdirSync(tempRoot, { recursive: true, mode: 0o700 });
    directory = mkdtempSync(join(tempRoot, "managed-cli-"));
    symlinkSync(executable, join(directory, "aidevops"));
    cliProjections.set(key, directory);
    return directory;
  } catch {
    try {
      if (directory) rmSync(directory, { recursive: true, force: true });
    } catch { /* unavailable projection must not break unrelated tools */ }
    return "";
  }
}

// Plugin-native subprocesses (including MCP launchers) retain the normalized
// inherited PATH. Narrow worker-tool projection is opt-in above, never global.
process.env.PATH = runtimePath(process.env.PATH);
