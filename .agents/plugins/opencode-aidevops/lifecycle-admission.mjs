// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { join } from "path";
import { patchTargetPaths } from "./worker-write-fence.mjs";
import { isApplyPatchMutationTool, isDirectFileMutationTool } from "./quality-hooks-git-safety.mjs";
import { parsePolicyPayload, runPolicyHelper } from "./quality-hooks-policy-runner.mjs";

export function admitToolOwner({ scriptsDir, repositoryDir, input, output, bash, bounded }) {
  // Unsupported hosts cannot run the native cleanup collector either.
  if (!["linux", "darwin"].includes(process.platform)) return;
  const args = output.args || {};
  const fileMutation = isDirectFileMutationTool(input.tool);
  if (!fileMutation && !bash && !(bounded && args.action === "start")) return;
  const cwd = bash
    ? (args.workdir ?? args.cwd ?? process.cwd())
    : (args.workdir || args.cwd || repositoryDir || process.cwd());
  let paths = [];
  if (fileMutation) {
    paths = isApplyPatchMutationTool(input.tool)
      ? patchTargetPaths(args.patchText || args.patch_text || "", cwd)
      : [args.filePath || args.file_path || args.path || ""];
    if (!paths.length || paths.some((path) => !path)) {
      throw new Error("BLOCKED: lifecycle ownership requires explicit write targets");
    }
  }
  const sessionID = input.sessionID || input.sessionId || input.session?.id || "";
  // #aidevops:trust-boundary — these identities come from the runtime, not tool args.
  const helperArgs = ["-E", "-s", "-B", join(scriptsDir, "worker-lifecycle-session-helper.py"),
    "--cwd", cwd, "--runtime-pid", String(process.pid), "--session-id", sessionID];
  for (const path of paths) helperArgs.push("--path", path);
  if (bash && typeof args.command === "string") helperArgs.push("--command", args.command);
  if (bounded && Array.isArray(args.command)) helperArgs.push("--argv-json", JSON.stringify(args.command));
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
