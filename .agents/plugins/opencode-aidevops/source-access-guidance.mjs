// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const ROOT_BROKER = "/etc/aidevops/source-access/source-access-helper.py";
const REQUEST_ID_PATTERN = /^[a-f0-9]{32,64}$/;

function readVersion(path) {
  try {
    return readFileSync(path, "utf8").trim().split(/\r?\n/, 1)[0];
  } catch {
    return "";
  }
}

// Preserve the loaded version across updates; never substitute the new on-disk
// value for a missing startup value (an unknown version cannot prove drift).
const LOADED_VERSION = readVersion(join(homedir(), ".aidevops", "agents", "VERSION"));

export function sourceAccessVersionChanged(scriptsDir, loadedVersion = LOADED_VERSION) {
  const deployedVersion = readVersion(join(dirname(scriptsDir), "VERSION"));
  return Boolean(loadedVersion && deployedVersion && loadedVersion !== deployedVersion);
}

function runSourceAccessHelper(helperArgs, run) {
  return String(run("/usr/bin/python3", ["-I", "-B", ROOT_BROKER, ...helperArgs], {
    encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 15000,
  })).trim();
}

export function brokerMatchesCurrentRelease(brokerMatches, scriptsDir) {
  try {
    return brokerMatches({ scriptsDir });
  } catch {
    return false;
  }
}

export function applyApprovedRead(args, approval, filePath, log) {
  if (!approval?.approvedPath) return false;
  if (Object.hasOwn(args, "filePath")) args.filePath = approval.approvedPath;
  if (Object.hasOwn(args, "file_path")) args.file_path = approval.approvedPath;
  log("INFO", `[source-access] verified session-bound read approval for ${filePath}`);
  return true;
}

export function requestApprovalId({ brokerCurrent, filePath, reason, requestRun, sessionId }) {
  if (!brokerCurrent) return "";
  try {
    const requestId = runSourceAccessHelper(
      ["request", "--session", sessionId, "--path", filePath, "--reason", reason], requestRun,
    );
    return REQUEST_ID_PATTERN.test(requestId) ? requestId : "";
  } catch {
    // Request generation is advisory; the original guard remains authoritative.
    return "";
  }
}

export function checkGateWithApprovalInstructions({
  args, brokerCurrent, checkSecretReadGate, filePath, log, requestId, denialReason = "missing", tool,
  staleVersion = false,
}) {
  try {
    checkSecretReadGate(tool, args, log);
  } catch (error) {
    const originalMessage = error instanceof Error ? error.message : String(error);
    if (staleVersion) {
      throw new Error(`${originalMessage}\n\naidevops was updated after this OpenCode session started; ` +
        "restart OpenCode to use the updated source-access flow.");
    }
    if (!brokerCurrent) {
      throw new Error(
        `${originalMessage}\n\nThis aidevops release changed the root-owned source-access broker. ` +
          "Run aidevops setup --scope source-access from an interactive terminal to reconcile it.",
      );
    }
    if (!requestId) throw error;
    const explanation = {
      drift: "The prior approval was invalidated by an unobserved content transition.",
      expired: "The prior approval has expired.",
      invalid: "The prior approval was revoked or its repository/worktree identity is no longer valid.",
      missing: "No source-access approval exists for this exact path and session.",
    }[denialReason] || "No valid source-access approval exists for this exact path and session.";
    throw new Error(
      `${originalMessage}\n\n${explanation}\n\nCheck current approvals with aidevops source-access status.\n` +
        "To approve only this tracked source path for this session, run in an interactive terminal:\n" +
        `sudo -k /usr/bin/python3 -I -B ${ROOT_BROKER} approve ${requestId} --ttl 12h\n\n` +
        "For one approval covering several exact tracked paths, create one request with " +
        "`aidevops source-access request --session <session> --reason 'secret-bearing basename' " +
        "--path <path-1> --path <path-2> ...`, then approve the returned request ID.",
    );
  }
}
