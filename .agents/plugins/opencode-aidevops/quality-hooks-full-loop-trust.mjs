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
  const wrapperMatches = [...command.matchAll(
    /(?:^|[($;|&\s])(?<wrapper>[^\s'";$|&()]*full-loop-helper\.sh)\s+commit-and-pr(?:\s|$)/g,
  )];
  if (wrapperMatches.length === 0) return { command, trusted: false };

  const deployedPath = resolve(scriptsDir, "full-loop-helper.sh");
  const activeDeployedPath = resolve(activeScriptsDir, "full-loop-helper.sh");
  const repositoryPath = resolve(cwd, ".agents", "scripts", "full-loop-helper.sh");
  let normalisedCommand = command;
  for (const wrapperMatch of wrapperMatches.reverse()) {
    const wrapper = wrapperMatch.groups.wrapper;
    let candidatePath;
    if (wrapper === "full-loop-helper.sh") candidatePath = deployedPath;
    else if (wrapper.startsWith("~/")) candidatePath = resolve(homedir(), wrapper.slice(2));
    else if (wrapper.startsWith("$PWD/")) candidatePath = resolve(cwd, wrapper.slice(5));
    else candidatePath = resolve(cwd, wrapper);
    if ([deployedPath, repositoryPath].includes(candidatePath)) {
      if (!existsSync(candidatePath)) return { command, trusted: false };
      continue;
    }
    if (candidatePath !== activeDeployedPath || !existsSync(deployedPath)) {
      return { command, trusted: false };
    }
    const aliasStillPinned = resolvesTo(candidatePath, deployedPath);
    if (!aliasStillPinned
      && activeScriptsDirBinding?.activeScriptsDir !== resolve(activeScriptsDir)) {
      return { command, trusted: false };
    }
    if (aliasStillPinned) continue;

    // The activation link may rotate after OpenCode pins its immutable runtime
    // bundle. Keep the sanctioned deployed alias bound to that pinned helper
    // instead of either rejecting it or executing a newer bundle in-process.
    const wrapperStart = wrapperMatch.index + wrapperMatch[0].indexOf(wrapper);
    normalisedCommand = normalisedCommand.slice(0, wrapperStart)
      + shellQuote(deployedPath)
      + normalisedCommand.slice(wrapperStart + wrapper.length);
  }
  return { command: normalisedCommand, trusted: true };
}
