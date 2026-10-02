// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "child_process";

const DEFAULT_POLICY_HELPER_TIMEOUT_MS = 10000;
const GIT_NETWORK_POLICY_HELPER_TIMEOUT_MS = 30000;
const POLICY_HELPER_RETRY_TIMEOUT_MULTIPLIER = 3;

export function parsePolicyPayload(raw) {
  const result = JSON.parse(raw);
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new TypeError("policy returned a non-object payload");
  }
  return result;
}

export function gitNetworkPolicyOperation(helperArgs) {
  const commandIndex = helperArgs.indexOf("--command");
  if (commandIndex < 0) return null;
  // This only selects a time budget, never grants command authority. The
  // shared parser still evaluates the entire command, including compounds.
  return helperArgs[commandIndex + 1]?.match(
    /\bgit\s+(?:(?:-C|-c|--git-dir|--work-tree)\s+\S+\s+)*(push|fetch)\b/,
  )?.[1] ?? null;
}

// Outbound HTTP(S) tool commands (curl, wget, fetch in node/python one-liners,
// or a literal http(s) URL) need the same larger budget as git network
// operations (GH#33406). Only selects a time budget; never grants authority.
export function httpNetworkPolicyOperation(helperArgs) {
  const commandIndex = helperArgs.indexOf("--command");
  if (commandIndex < 0) return false;
  const command = helperArgs[commandIndex + 1];
  if (typeof command !== "string") return false;
  return /\b(?:curl|wget)\b|\bfetch\s*\(|https?:\/\//.test(command);
}

function policyHelperTimeoutMs(helperArgs) {
  const raw = String(process.env.AIDEVOPS_POLICY_HELPER_TIMEOUT_MS ?? "").trim();
  if (/^[1-9]\d{0,6}$/.test(raw)) return Number(raw);
  return gitNetworkPolicyOperation(helperArgs) || httpNetworkPolicyOperation(helperArgs)
    ? GIT_NETWORK_POLICY_HELPER_TIMEOUT_MS
    : DEFAULT_POLICY_HELPER_TIMEOUT_MS;
}

export function isPolicyHelperTimeout(error) {
  return error?.code === "ETIMEDOUT";
}

// Policy helpers are read-only evaluations, so one retry with a larger budget
// is safe. Host load (spawned jq/network helpers at load average > ncpu)
// routinely pushes a normal evaluation past the base budget (GH#32955).
// A second timeout propagates; callers map it with transientPolicyTimeoutError.
export function runPolicyHelper(helperArgs, execOptions) {
  const timeout = policyHelperTimeoutMs(helperArgs);
  const options = { ...execOptions, encoding: "utf8" };
  try {
    return execFileSync("python3", helperArgs, { ...options, timeout });
  } catch (error) {
    if (!isPolicyHelperTimeout(error)) throw error;
  }
  return execFileSync("python3", helperArgs, {
    ...options,
    timeout: timeout * POLICY_HELPER_RETRY_TIMEOUT_MULTIPLIER,
  });
}

export function transientPolicyTimeoutError(policyName, operation = null) {
  let recovery = "";
  if (operation === "push") recovery = "\nTERMINAL_BLOCKER_REASON=push_policy_timeout";
  else if (operation === "network") recovery = "\nTERMINAL_BLOCKER_REASON=network_policy_timeout";
  return new Error(
    `BLOCKED: ${policyName} policy timed out under host load (transient infrastructure timeout, not a policy decision); retry the same command${recovery}`,
  );
}

// Map a failed helper execution to the fail-closed error a gate throws.
export function policyExecutionFailure(policyName, error) {
  if (isPolicyHelperTimeout(error)) return transientPolicyTimeoutError(policyName);
  const detail = error?.stderr?.toString().trim() || error?.message || "policy check failed";
  return new Error(`BLOCKED: ${policyName} policy failed closed: ${detail}`);
}
