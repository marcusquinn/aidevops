// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Body-file repair helpers for the signature footer gate. Extracted from
// quality-hooks-signature.mjs to keep the gate orchestrator below the qlty
// file-complexity and return-statement smell thresholds.

import { existsSync, readFileSync, appendFileSync, realpathSync } from "fs";
import { execFileSync } from "child_process";
import { isAbsolute, resolve, sep } from "path";
import { tmpdir } from "os";

import { FAIL_REASON } from "./quality-hooks-signature-failures.mjs";

function hasPriorSameCommandBodyFileCreation(cmd, filePath) {
  if (!filePath) return false;
  const bodyFileIdx = cmd.lastIndexOf("--body-file");
  if (bodyFileIdx <= 0) return false;
  const beforeGh = cmd.slice(0, bodyFileIdx);
  if (!beforeGh.includes(filePath)) return false;
  const escaped = filePath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const quotedPath = `["']?${escaped}["']?`;
  const creationPatterns = [
    new RegExp(`(?:^|[;&|]|&&|\\|\\|)\\s*(?:echo|printf|cat|tee)\\b[\\s\\S]*(?:>|>>)\\s*${quotedPath}`),
    new RegExp(`(?:^|[;&|]|&&|\\|\\|)\\s*(?:cp|mv)\\b[\\s\\S]+\\s+${quotedPath}`),
    new RegExp(`(?:^|[;&|]|&&|\\|\\|)\\s*touch\\s+${quotedPath}`),
  ];
  return creationPatterns.some((pattern) => pattern.test(beforeGh));
}

function isPathWithin(childPath, parentPath) {
  const parentPrefix = parentPath.endsWith(sep) ? parentPath : `${parentPath}${sep}`;
  return childPath === parentPath || childPath.startsWith(parentPrefix);
}

function safeRealpath(path) {
  try {
    return realpathSync(path);
  } catch {
    return "";
  }
}

function gitValue(args) {
  try {
    return execFileSync("git", args, {
      encoding: "utf-8",
      timeout: 1000,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
}

function gitCommonDir(path) {
  const topLevel = gitValue(["-C", path, "rev-parse", "--show-toplevel"]);
  if (!topLevel) return "";
  const commonDir = gitValue(["-C", topLevel, "rev-parse", "--git-common-dir"]);
  if (!commonDir) return "";
  return safeRealpath(isAbsolute(commonDir) ? commonDir : resolve(topLevel, commonDir));
}

function sameGitRepository(pathA, pathB) {
  const commonA = gitCommonDir(pathA);
  const commonB = gitCommonDir(pathB);
  return Boolean(commonA && commonB && commonA === commonB);
}

function resolveAllowedBodyFilePath(filePath, commandWorkdir = process.cwd()) {
  const realCommandWorkdir = safeRealpath(commandWorkdir) || process.cwd();
  const candidatePath = isAbsolute(filePath) ? filePath : resolve(realCommandWorkdir, filePath);
  const realFilePath = realpathSync(candidatePath);
  const allowedRoots = [realCommandWorkdir, process.cwd(), tmpdir()]
    .filter((root) => existsSync(root))
    .map((root) => realpathSync(root));
  if (allowedRoots.some((root) => isPathWithin(realFilePath, root))) {
    return { status: "ok", filePath: realFilePath };
  }
  if (sameGitRepository(realFilePath, realCommandWorkdir)) {
    return { status: "ok", filePath: realFilePath };
  }
  return {
    status: "fail",
    reason: FAIL_REASON.BODY_FILE_OUTSIDE_ALLOWED_ROOT,
    detail: `${filePath} -> ${realFilePath}`,
  };
}

function okResult(cmd) {
  return { status: "ok", cmd };
}

function missingHelperResult(helperPath, log) {
  log("WARN", `gh-signature-helper.sh not found at ${helperPath}; cannot repair`);
  return { status: "fail", reason: FAIL_REASON.HELPER_MISSING, detail: helperPath };
}

function repairResolvedBodyFile(cmd, resolvedFilePath, helperPath, log, options) {
  const current = readFileSync(resolvedFilePath, "utf-8");
  if (current.includes(options.sigMarker)) return okResult(cmd);
  if (options.isMachineProtocolCommand(current)) {
    log("INFO", `Body-file ${resolvedFilePath} contains machine-protocol content; no repair needed`);
    return okResult(cmd);
  }
  if (!existsSync(helperPath)) return missingHelperResult(helperPath, log);
  const sigResult = options.generateSignature(helperPath, current, log);
  if (sigResult.status === "fail") return sigResult;
  appendFileSync(resolvedFilePath, sigResult.sig);
  log("INFO", `Auto-appended signature footer to body-file ${resolvedFilePath} (t2685)`);
  return okResult(cmd);
}

function handleBodyFileRepairError(cmd, filePath, error, log) {
  const reason =
    error.code === "ENOENT" ? FAIL_REASON.FILE_NOT_FOUND : FAIL_REASON.FILE_UNREADABLE;
  if (reason === FAIL_REASON.FILE_NOT_FOUND && hasPriorSameCommandBodyFileCreation(cmd, filePath)) {
    log(
      "INFO",
      `Body-file ${filePath} appears to be created before gh in the same bash command; deferring signature injection to PATH shim`,
    );
    return okResult(cmd);
  }
  log("WARN", `Could not repair --body-file ${filePath}: ${error.message} (${reason})`);
  return { status: "fail", reason, detail: `${filePath}: ${error.message}` };
}

/**
 * Repair a `--body-file PATH` form by appending the signature footer to the
 * referenced file if missing.
 * @param {string} cmd
 * @param {string} filePath
 * @param {string} helperPath
 * @param {Function} log
 * @param {{ commandWorkdir?: string, sigMarker: string, isMachineProtocolCommand: Function, generateSignature: Function }} options
 * @returns {{ status: "ok", cmd: string } | { status: "fail", reason: string, detail: string }}
 */
export function repairBodyFile(cmd, filePath, helperPath, log, options) {
  try {
    const resolved = resolveAllowedBodyFilePath(filePath, options.commandWorkdir);
    if (resolved.status === "fail") {
      log("WARN", `Refusing --body-file outside allowed roots: ${resolved.detail}`);
      return resolved;
    }
    return repairResolvedBodyFile(cmd, resolved.filePath, helperPath, log, options);
  } catch (e) {
    return handleBodyFileRepairError(cmd, filePath, e, log);
  }
}
