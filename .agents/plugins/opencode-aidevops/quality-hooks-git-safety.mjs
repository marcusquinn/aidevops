// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync } from "fs";
import { homedir } from "os";
import { join, resolve } from "path";
import {
  appendRuntimePolicyArgs,
  commandPolicyError,
  executeCommandPolicy,
} from "./quality-hooks-command-policy.mjs";
import { classifyFullLoopCommitAndPr } from "./quality-hooks-full-loop-trust.mjs";
import {
  parsePolicyPayload,
  policyExecutionFailure,
  runPolicyHelper,
} from "./quality-hooks-policy-runner.mjs";

export { bindActiveScriptsDir } from "./quality-hooks-full-loop-trust.mjs";
export { checkArgvSafetyGate } from "./quality-hooks-command-policy.mjs";

function normaliseToolName(tool) {
  if (typeof tool !== "string") return "";
  return tool
    .replaceAll("::", ".")
    .replaceAll("/", ".")
    .split(".")
    .at(-1)
    .replaceAll("-", "_")
    .toLowerCase();
}

export function isDirectFileMutationTool(tool) {
  return Boolean(directFileMutationKind(tool));
}

export function isApplyPatchMutationTool(tool) {
  return directFileMutationKind(tool) === "apply_patch";
}

export function directFileMutationKind(tool) {
  const normalized = normaliseToolName(tool);
  if (["write", "write_file"].includes(normalized)) return "write";
  if (["edit", "edit_file"].includes(normalized)) return "edit";
  if (["apply_patch", "applypatch"].includes(normalized)) return "apply_patch";
  return "";
}

export function directFileMutations(tool, args = {}, repositoryDir = "") {
  const cwd = args.workdir || args.cwd || repositoryDir || process.cwd();
  const kind = directFileMutationKind(tool);
  if (kind !== "apply_patch") {
    const filePath = args.filePath || args.file_path || args.path || "";
    if (!filePath) return [];
    return [{
      filePath: resolve(cwd, filePath),
      kind,
      content: args.content,
      oldString: args.oldString ?? args.old_string,
      newString: args.newString ?? args.new_string,
      replaceAll: args.replaceAll === true || args.replace_all === true,
    }];
  }
  const patchText = typeof args.patchText === "string" ? args.patchText : args.patch_text || "";
  const headers = [...patchText.matchAll(/^\*\*\* (Update|Delete) File: (.+)$/gm)];
  return headers.map((match, index) => ({
    filePath: resolve(cwd, match[2].trim()),
    kind: match[1] === "Update" ? kind : "delete",
    patchText: patchText.slice(match.index + match[0].length, headers[index + 1]?.index),
  }));
}

function replaceExactOnce(content, oldString, newString) {
  const first = content.indexOf(oldString);
  if (first < 0 || content.indexOf(oldString, first + oldString.length) >= 0) return false;
  return content.slice(0, first) + newString + content.slice(first + oldString.length);
}

export function expectedSimpleMutationContent(state, mutation) {
  const content = state.content.toString("utf8");
  let updated;
  if (mutation.kind === "write") {
    updated = typeof mutation.content === "string" ? mutation.content : false;
  } else if (mutation.kind === "edit") {
    const validEdit = typeof mutation.oldString === "string" && mutation.oldString &&
      typeof mutation.newString === "string" && content.includes(mutation.oldString);
    if (!validEdit) return false;
    updated = mutation.replaceAll
      ? content.replaceAll(mutation.oldString, mutation.newString)
      : replaceExactOnce(content, mutation.oldString, mutation.newString);
  }
  return updated === undefined || updated === false ? updated : Buffer.from(updated);
}

export function checkCanonicalWriteSafetyGate(
  filePath,
  scriptsDir,
  cwd = process.cwd(),
  patchText = null,
) {
  const helper = join(scriptsDir, "canonical-write-policy-helper.py");
  if (!existsSync(helper)) {
    throw new Error("BLOCKED: required canonical-write policy helper is missing");
  }
  let raw = "";
  try {
    const helperArgs = [
      helper,
      patchText === null ? "check-write" : "check-patch",
      "--cwd",
      cwd,
    ];
    if (patchText === null) helperArgs.push("--path", filePath || "");
    raw = runPolicyHelper(helperArgs, {
      input: patchText === null
        ? undefined
        : (typeof patchText === "string" ? patchText : ""),
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (error) {
    throw policyExecutionFailure("canonical-write", error);
  }
  let result;
  try {
    result = parsePolicyPayload(raw);
  } catch {
    throw new Error("BLOCKED: canonical-write policy returned malformed output");
  }
  if (result.decision !== "allow") {
    throw new Error(
      `BLOCKED by canonical write policy: ${result.reason || "invalid policy response"}. ACTION_REQUIRED=create_or_use_linked_worktree`,
    );
  }
}

export function checkCommandSafetyGate(command, scriptsDir, cwd = process.cwd(), options = {}) {
  if (typeof command !== "string" || !command) return;
  const helper = join(scriptsDir, "command-policy-helper.py");
  if (!existsSync(helper)) {
    throw new Error("BLOCKED: required command policy helper is missing");
  }
  const namesFullLoopCommitAndPr = /full-loop-helper\.sh\s+commit-and-pr(?:\s|$)/.test(command);
  const activeScriptsDir = options.activeScriptsDir
    ?? join(homedir(), ".aidevops", "agents", "scripts");
  const fullLoop = classifyFullLoopCommitAndPr(
    command,
    scriptsDir,
    cwd,
    activeScriptsDir,
    options.activeScriptsDirBinding,
  );
  if (namesFullLoopCommitAndPr && !fullLoop.trusted) {
    throw new Error("BLOCKED: unclassified nested Git invocation from an untrusted full-loop wrapper");
  }
  // #aidevops:trust-boundary — only the repository-owned full-loop wrapper
  // receives nested Git authority, and only from a verified linked worktree.
  const guardedCommand = fullLoop.trusted
    ? "git commit --dry-run"
    : command;
  const helperArgs = [helper, "check-command", "--cwd", cwd, "--command", guardedCommand];
  appendRuntimePolicyArgs(helperArgs, options);
  const result = executeCommandPolicy(helperArgs);
  if (result.decision !== "allow") {
    throw commandPolicyError(result);
  }
  return fullLoop.command;
}

export const checkCanonicalGitSafetyGate = checkCommandSafetyGate;
