// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, relative, resolve } from "node:path";

export const WORKSPACE_NOTICE_TEXT =
  "This session can't edit repo worktrees; open the repo's Tabby profile for implementation work.";

function resolveReal(path) {
  const absolute = resolve(path);
  try {
    return realpathSync(absolute);
  } catch {
    return absolute;
  }
}

/**
 * True when `directory` is outside the trusted Git workspace root
 * (`AIDEVOPS_GIT_WORKSPACE_ROOT`, default `~/Git`).
 * @param {string | undefined} directory
 * @param {Record<string, string | undefined>} [env]
 * @returns {boolean}
 */
export function isOutsideGitWorkspace(directory, env = process.env) {
  if (!directory) return false;
  const root = resolveReal(env.AIDEVOPS_GIT_WORKSPACE_ROOT || resolve(homedir(), "Git"));
  const rel = relative(root, resolveReal(directory));
  return rel === ".." || rel.startsWith("..") || isAbsolute(rel);
}

/**
 * Session-start notice for sessions rooted outside the Git workspace: one toast
 * per plugin instance plus a short system note. Read-only work stays allowed.
 * @param {object} deps
 * @param {object} deps.client
 * @param {string} deps.directory
 * @param {() => boolean} [deps.isHeadless]
 * @param {Record<string, string | undefined>} [deps.env]
 * @returns {(output: { system?: string[] }) => Promise<void>}
 */
export function createWorkspaceNotice({ client, directory, isHeadless = () => false, env = process.env }) {
  let toasted = false;
  return async (output) => {
    if (isHeadless() || !isOutsideGitWorkspace(directory, env)) return;
    if (Array.isArray(output?.system)) output.system.push(`## Non-repo session\n${WORKSPACE_NOTICE_TEXT}`);
    if (toasted) return;
    toasted = true;
    try {
      await client?.tui?.showToast?.({
        body: { title: "Not a repo session", message: WORKSPACE_NOTICE_TEXT, variant: "warning" },
      });
    } catch {
      // Toasts are advisory; never block the request.
    }
  };
}
