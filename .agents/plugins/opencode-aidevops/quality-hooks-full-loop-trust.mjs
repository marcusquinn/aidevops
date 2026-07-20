// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, realpathSync } from "fs";
import { homedir } from "os";
import { resolve } from "path";

function resolvesTo(candidatePath, expectedPath) {
  try {
    return realpathSync(candidatePath) === realpathSync(expectedPath);
  } catch {
    return false;
  }
}

function shellQuote(value) {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

export function bindActiveScriptsDir(activeScriptsDir, scriptsDir) {
  const activeHelper = resolve(activeScriptsDir, "full-loop-helper.sh");
  const pinnedHelper = resolve(scriptsDir, "full-loop-helper.sh");
  return resolvesTo(activeHelper, pinnedHelper)
    ? Object.freeze({ activeScriptsDir: resolve(activeScriptsDir) })
    : null;
}

export function classifyFullLoopCommitAndPr(
  command,
  scriptsDir,
  cwd,
  activeScriptsDir,
  activeScriptsDirBinding,
) {
  const wrapperMatch = command.match(
    /(?:^|[($;|&\s])(?<wrapper>[^\s'";$|&()]*full-loop-helper\.sh)\s+commit-and-pr(?:\s|$)/,
  );
  if (!wrapperMatch) return { command, trusted: false };

  const wrapper = wrapperMatch.groups.wrapper;
  const deployedPath = resolve(scriptsDir, "full-loop-helper.sh");
  const activeDeployedPath = resolve(activeScriptsDir, "full-loop-helper.sh");
  const repositoryPath = resolve(cwd, ".agents", "scripts", "full-loop-helper.sh");
  let candidatePath;
  if (wrapper === "full-loop-helper.sh") candidatePath = deployedPath;
  else if (wrapper.startsWith("~/")) candidatePath = resolve(homedir(), wrapper.slice(2));
  else if (wrapper.startsWith("$PWD/")) candidatePath = resolve(cwd, wrapper.slice(5));
  else candidatePath = resolve(cwd, wrapper);
  if ([deployedPath, repositoryPath].includes(candidatePath)) {
    return { command, trusted: existsSync(candidatePath) };
  }
  if (candidatePath !== activeDeployedPath || !existsSync(deployedPath)) {
    return { command, trusted: false };
  }
  const aliasStillPinned = resolvesTo(candidatePath, deployedPath);
  if (!aliasStillPinned
    && activeScriptsDirBinding?.activeScriptsDir !== resolve(activeScriptsDir)) {
    return { command, trusted: false };
  }

  // The activation link may rotate after OpenCode pins its immutable runtime
  // bundle. Keep the sanctioned deployed alias bound to that pinned helper
  // instead of either rejecting it or executing a newer bundle in-process.
  let normalisedCommand = command;
  if (!aliasStillPinned) {
    const wrapperStart = wrapperMatch.index + wrapperMatch[0].indexOf(wrapper);
    normalisedCommand = command.slice(0, wrapperStart)
      + shellQuote(deployedPath)
      + command.slice(wrapperStart + wrapper.length);
  }
  return { command: normalisedCommand, trusted: true };
}
