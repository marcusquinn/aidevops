// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync } from "fs";
import { join } from "path";
import { isWorkerContext, processStartIdentity } from "./process-start-identity.mjs";
import {
  isPolicyHelperTimeout,
  parsePolicyPayload,
  policyNetworkOperation,
  runPolicyHelper,
  transientPolicyTimeoutError,
} from "./quality-hooks-policy-runner.mjs";

const RUNTIME_PROCESS_IDENTITY = processStartIdentity(process.pid);

export function commandPolicyError(result) {
  return new Error(
    `BLOCKED by shared command policy (${result.decision || "forbid"}, ${result.rule_id || "policy.invalid-response"}): ${result.reason || "invalid policy response"}`,
  );
}

export function executeCommandPolicy(helperArgs) {
  let raw = "";
  let executionError = null;
  try {
    raw = runPolicyHelper(helperArgs, { stdio: ["ignore", "pipe", "pipe"] });
  } catch (error) {
    if (isPolicyHelperTimeout(error)) {
      throw transientPolicyTimeoutError("command", policyNetworkOperation(helperArgs));
    }
    executionError = error;
    raw = error?.stdout?.toString() || "";
  }
  let result;
  try {
    result = parsePolicyPayload(raw);
  } catch {
    const detail = executionError?.stderr?.toString().trim()
      || executionError?.message
      || "command policy returned malformed output";
    throw new Error(`BLOCKED: command policy failed closed: ${detail}`);
  }
  if (executionError) throw commandPolicyError(result);
  return result;
}

export function appendRuntimePolicyArgs(helperArgs, options) {
  // #aidevops:trust-boundary — process.pid and its start identity come from
  // the running OpenCode plugin host, never from the command being checked.
  helperArgs.push(
    "--runtime-pid",
    String(options.runtimePid ?? process.pid),
    "--runtime-process-identity",
    options.runtimeProcessIdentity ?? RUNTIME_PROCESS_IDENTITY,
  );
  if (options.processTableFixture) {
    helperArgs.push("--process-table-fixture", options.processTableFixture);
  }
  if (options.listenerTableFixture) {
    helperArgs.push("--listener-table-fixture", options.listenerTableFixture);
  }
  if (options.approvalHelper) {
    helperArgs.push("--approval-helper", options.approvalHelper);
  }
  const worker = options.worker ?? isWorkerContext();
  if (!worker) return;
  helperArgs.push(
    "--worker",
    "--worker-id",
    options.workerId || process.env.AIDEVOPS_WORKER_ID || "opencode-worker",
  );
  // #aidevops:trust-boundary — owned listener roots come only from this host's
  // bounded-operation table (supervisor PID + spawn-time start identity) and
  // are re-verified against the live process table by the policy helper.
  const roots = Array.isArray(options.ownedListenerRoots) ? options.ownedListenerRoots : [];
  if (roots.length > 0) helperArgs.push("--owned-listener-roots", JSON.stringify(roots));
}

/**
 * GH#33969: apply the shared worker command policy to an exact argv before a
 * bounded operation spawns it, so recognized clients get the same decision as
 * in Bash. Shell bodies the strict parser cannot represent (redirection,
 * background jobs) stay outside argv control, like unrecognized clients; the
 * worker egress backend owns whole-process enforcement.
 * @returns {object|null} policy result, or null when not applicable
 */
export function checkArgvSafetyGate(argv, scriptsDir, cwd = process.cwd(), options = {}) {
  const worker = options.worker ?? isWorkerContext();
  if (!worker || !Array.isArray(argv) || argv.length === 0) return null;
  const helper = join(scriptsDir, "command-policy-helper.py");
  if (!existsSync(helper)) {
    throw new Error("BLOCKED: required command policy helper is missing");
  }
  const helperArgs = [helper, "check-command", "--cwd", cwd, "--argv-json", JSON.stringify(argv)];
  appendRuntimePolicyArgs(helperArgs, { ...options, worker });
  let result;
  try {
    result = executeCommandPolicy(helperArgs);
  } catch (error) {
    if (/\(forbid, command\.parse-error\)/.test(error?.message || "")) return null;
    throw error;
  }
  if (result.decision !== "allow") throw commandPolicyError(result);
  return result;
}
