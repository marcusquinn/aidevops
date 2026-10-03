// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { lstatSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";

function hasUnsafeComponent(target) {
  let current = target;
  while (true) {
    try {
      if (lstatSync(current).isSymbolicLink()) return true;
    } catch (err) {
      if (err.code !== "ENOENT") return true;
    }
    const parent = dirname(current);
    if (parent === current) return false;
    current = parent;
  }
}

function isOutsideWorkspace(workspace, absolute) {
  const within = relative(workspace.directory, absolute);
  if (within === ".." || within.startsWith("../")) return true;
  return isAbsolute(within);
}

/** Normalize local Markdown artifact links against the managed MCP's real cwd. */
export function normalizeMcpArtifactPaths(input, output, workspaces) {
  const workspace = workspaces?.playwright;
  if (!workspace || !input?.tool?.startsWith("playwright_browser_") || typeof output?.output !== "string") return;
  const cwd = workspace.outputDirectory || resolve(workspace.directory, ".playwright-mcp");
  output.output = output.output.replace(/\]\(([^\s)]+)\)/g, (link, target) => {
    // Leave URLs, anchors and absolute links untouched, including file: URLs.
    if (/^[a-z][a-z\d+.-]*:|^[#/]|^\\/i.test(target)) return link;
    const absolute = resolve(cwd, target);
    if (isOutsideWorkspace(workspace, absolute)) return link;
    if (hasUnsafeComponent(`${cwd}/${target}`) || hasUnsafeComponent(absolute)) return link;
    return `](${absolute})`;
  });
}
