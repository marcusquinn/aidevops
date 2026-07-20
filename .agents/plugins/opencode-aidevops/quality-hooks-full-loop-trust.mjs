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

function resolveWrapperPath(wrapper, scriptsDir, cwd) {
  if (wrapper === "full-loop-helper.sh") {
    return resolve(scriptsDir, "full-loop-helper.sh");
  }
  if (wrapper.startsWith("~/")) return resolve(homedir(), wrapper.slice(2));
  if (wrapper.startsWith("$PWD/")) return resolve(cwd, wrapper.slice(5));
  return resolve(cwd, wrapper);
}

function classifyWrapperPath(
  wrapper,
  scriptsDir,
  cwd,
  activeScriptsDir,
  activeScriptsDirBinding,
) {
  const deployedPath = resolve(scriptsDir, "full-loop-helper.sh");
  const repositoryPath = resolve(cwd, ".agents", "scripts", "full-loop-helper.sh");
  const candidatePath = resolveWrapperPath(wrapper, scriptsDir, cwd);
  if ([deployedPath, repositoryPath].includes(candidatePath)) {
    return { deployedPath, trusted: existsSync(candidatePath), rewrite: false };
  }

  const activeDeployedPath = resolve(activeScriptsDir, "full-loop-helper.sh");
  if (candidatePath !== activeDeployedPath || !existsSync(deployedPath)) {
    return { deployedPath, trusted: false, rewrite: false };
  }
  if (resolvesTo(candidatePath, deployedPath)) {
    return { deployedPath, trusted: true, rewrite: false };
  }
  const bound = activeScriptsDirBinding?.activeScriptsDir === resolve(activeScriptsDir);
  return { deployedPath, trusted: bound, rewrite: bound };
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

  let normalisedCommand = command;
  for (const wrapperMatch of wrapperMatches.reverse()) {
    const wrapper = wrapperMatch.groups.wrapper;
    const classification = classifyWrapperPath(
      wrapper,
      scriptsDir,
      cwd,
      activeScriptsDir,
      activeScriptsDirBinding,
    );
    if (!classification.trusted) return { command, trusted: false };
    if (!classification.rewrite) continue;

    // The activation link may rotate after OpenCode pins its immutable runtime
    // bundle. Keep the sanctioned deployed alias bound to that pinned helper
    // instead of either rejecting it or executing a newer bundle in-process.
    const wrapperStart = wrapperMatch.index + wrapperMatch[0].indexOf(wrapper);
    normalisedCommand = normalisedCommand.slice(0, wrapperStart)
      + shellQuote(classification.deployedPath)
      + normalisedCommand.slice(wrapperStart + wrapper.length);
  }
  return { command: normalisedCommand, trusted: true };
}
