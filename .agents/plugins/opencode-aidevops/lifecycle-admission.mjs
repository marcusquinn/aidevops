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
  } catch (error) {
    let reason;
    try { reason = parsePolicyPayload(error.stdout?.toString()).reason; } catch { /* No safe payload. */ }
    const inspectionCommand = 'python3 -E -s -B "$HOME/.aidevops/agents/worker-lifecycle/worker-registry.py" --state-dir <state-directory> status';
    if (["schema-one-with-admission-state", "schema-one-with-generation-marker"].includes(reason)) {
      throw new Error(`BLOCKED: ${reason}; conflicting schema-1 state is outside observe-only compatibility; no write authorized. Inspect read-only with ${inspectionCommand} and coordinate recovery with all clients. Do not reset, downgrade, migrate, or perform an uncoordinated upgrade`);
    }
    if (reason === "explicit-schema-upgrade-required") {
      throw new Error(`BLOCKED: explicit-schema-upgrade-required; schema-1 observe-only compatibility requires an unmarked linked worktree and valid observation store. Inspect with ${inspectionCommand}; coordinate all older clients before any explicit schema upgrade. No production upgrade command is installed; never reset or downgrade live state`);
    }
    throw new Error("BLOCKED: lifecycle owner admission is unavailable; no write authorized");
  }
  if (result.status === "coverage-gap" && result.reason === "schema-upgrade-required"
      && result.cleanup_authorized === false) {
    // Observation is not ownership. Independent command/canonical-write gates
    // remain mandatory; the console router persists this diagnostic off-TUI.
    console.error("[aidevops] [worker-lifecycle] coverage-gap: schema-upgrade-required; observe-only, no owner admitted or cleanup authorized");
    return;
  }
  if (!["admitted", "excluded-unregistered", "not-applicable"].includes(result.status)) {
    throw new Error("BLOCKED: lifecycle owner admission was not confirmed");
  }
}
