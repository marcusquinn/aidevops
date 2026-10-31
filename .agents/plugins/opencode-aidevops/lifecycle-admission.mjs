// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { join } from "path";
import { patchTargetPaths } from "./worker-write-fence.mjs";
import { isApplyPatchMutationTool, isDirectFileMutationTool } from "./quality-hooks-git-safety.mjs";
import { parsePolicyPayload, runPolicyHelper } from "./quality-hooks-policy-runner.mjs";

function ownerWorkingDirectory(args, repositoryDir, bash) {
  return bash
    ? (args.workdir ?? args.cwd ?? process.cwd())
    : (args.workdir || args.cwd || repositoryDir || process.cwd());
}

function mutationPaths(input, args, cwd) {
  const paths = isApplyPatchMutationTool(input.tool)
    ? patchTargetPaths(args.patchText || args.patch_text || "", cwd)
    : [args.filePath || args.file_path || args.path || ""];
  if (!paths.length || paths.some((path) => !path)) {
    throw new Error("BLOCKED: lifecycle ownership requires explicit write targets");
  }
  return paths;
}

function ownerArguments(scriptsDir, input, args, context) {
  const { cwd, fileMutation, bash, bounded } = context;
  const paths = fileMutation ? mutationPaths(input, args, cwd) : [];
  const sessionID = input.sessionID || input.sessionId || input.session?.id || "";
  // #aidevops:trust-boundary — these identities come from the runtime, not tool args.
  const helperArgs = ["-E", "-s", "-B", join(scriptsDir, "worker-lifecycle-session-helper.py"),
    "--cwd", cwd, "--runtime-pid", String(process.pid), "--session-id", sessionID];
  for (const path of paths) helperArgs.push("--path", path);
  if (bash && typeof args.command === "string") helperArgs.push("--command", args.command);
  if (bounded && Array.isArray(args.command)) helperArgs.push("--argv-json", JSON.stringify(args.command));
  return helperArgs;
}

export function admitToolOwner({ scriptsDir, repositoryDir, input, output, bash, bounded }) {
  // Unsupported hosts cannot run the native cleanup collector either.
  if (!["linux", "darwin"].includes(process.platform)) return;
  const args = output.args || {};
  const fileMutation = isDirectFileMutationTool(input.tool);
  if (!fileMutation && !bash && !(bounded && args.action === "start")) return;
  const helperArgs = ownerArguments(scriptsDir, input, args, {
    cwd: ownerWorkingDirectory(args, repositoryDir, bash), fileMutation, bash, bounded,
  });
  let result;
  try {
    // Admission replay is idempotent, including a retry after a lost acknowledgement.
    result = parsePolicyPayload(runPolicyHelper(helperArgs, { stdio: ["ignore", "pipe", "pipe"] }));
  } catch {
    throw new Error("BLOCKED: lifecycle owner admission is unavailable; no write authorized");
  }
  if (!["admitted", "excluded-unregistered", "not-applicable"].includes(result.status)) {
    throw new Error("BLOCKED: lifecycle owner admission was not confirmed");
  }
}
