// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { join } from "path";
import { patchTargetPaths } from "./worker-write-fence.mjs";
import { isApplyPatchMutationTool, isDirectFileMutationTool } from "./quality-hooks-git-safety.mjs";
import { parsePolicyPayload, runPolicyHelper } from "./quality-hooks-policy-runner.mjs";
import { runtimeOwner } from "./runtime-owner.mjs";

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

// Recovery guidance per safe helper reason; never includes host paths or secrets.
const REASON_GUIDANCE = {
  "runtime-owner-unresolved": "the runtime serving this session has no process generation proof, so no linked-worktree write is authorized. Recovery: open a new OpenCode tab or restart OpenCode; canonical and non-repository targets remain available",
  "git-target-unavailable": "a git -C/--git-dir/--work-tree target in the command is not a readable Git repository. Recovery: use an absolute repository path or the tool workdir",
  "inconsistent-git-target": "the command's Git target resolves to inconsistent repository metadata. Recovery: target the worktree root with an absolute path or the tool workdir",
  "target-classification-unavailable": "a write target could not be classified. Recovery: use an absolute path inside an existing directory",
  "explicit-absolute-context-required": "the working directory must be absolute. Recovery: pass an absolute workdir",
  "invalid-session-identity": "the runtime supplied no valid session identity. Recovery: run the tool from an OpenCode session or open a new tab",
};

/** Accept only short protocol tokens from the helper, never free-form text. */
function safeReason(value) {
  return typeof value === "string" && /^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(value) ? value : "";
}

function failureReason(error) {
  try {
    const reason = safeReason(parsePolicyPayload(error?.stdout?.toString()).reason);
    if (reason) return reason;
  } catch { /* No JSON payload; fall back to exit evidence. */ }
  if (error?.code === "ETIMEDOUT") return "helper-timeout";
  if (Number.isInteger(error?.status)) return `helper-exit-${error.status}`;
  return safeReason(error?.code) || "helper-unavailable";
}

function ownerArguments(scriptsDir, input, args, context) {
  const { cwd, fileMutation, bash, bounded } = context;
  const paths = fileMutation ? mutationPaths(input, args, cwd) : [];
  const sessionID = input.sessionID || input.sessionId || input.session?.id || "";
  // #aidevops:trust-boundary — these identities come from the runtime, not tool args.
  // An unproven runtime sends an empty PID; the helper still admits non-linked
  // targets and refuses linked ones with runtime-owner-unresolved (GH#36430).
  const owner = runtimeOwner(sessionID);
  const helperArgs = ["-E", "-s", "-B", join(scriptsDir, "worker-lifecycle-session-helper.py"),
    "--cwd", cwd, "--runtime-pid", owner.pid, "--session-id", sessionID];
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
    const reason = failureReason(error);
    const inspectionCommand = 'python3 -E -s -B "$HOME/.aidevops/agents/worker-lifecycle/worker-registry.py" --state-dir <state-directory> status';
    if (["schema-one-with-admission-state", "schema-one-with-generation-marker"].includes(reason)) {
      throw new Error(`BLOCKED: ${reason}; conflicting schema-1 state is outside observe-only compatibility; no write authorized. Inspect read-only with ${inspectionCommand} and coordinate recovery with all clients. Do not reset, downgrade, migrate, or perform an uncoordinated upgrade`);
    }
    if (reason === "explicit-schema-upgrade-required") {
      throw new Error(`BLOCKED: explicit-schema-upgrade-required; schema-1 observe-only compatibility requires an unmarked linked worktree and valid observation store. Inspect with ${inspectionCommand}; coordinate all older clients before any explicit schema upgrade. No production upgrade command is installed; never reset or downgrade live state`);
    }
    if (REASON_GUIDANCE[reason]) {
      throw new Error(`BLOCKED: ${reason}; ${REASON_GUIDANCE[reason]}`);
    }
    throw new Error(`BLOCKED: lifecycle owner admission is unavailable (${reason}); no write authorized`);
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
