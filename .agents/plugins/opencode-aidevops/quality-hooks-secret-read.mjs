// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// Secret/private-key pre-read guard for OpenCode file-read tools.

import { execFileSync } from "child_process";
import { lstatSync, realpathSync } from "fs";
import { basename, dirname, normalize, resolve } from "path";

const SECRET_BASENAME_RE = /^(id_(rsa|dsa|ecdsa|ed25519)|\.env(\..*)?|credentials(\.sh|\.json|\.ya?ml)?|service-account(\.json)?|kubeconfig|config\.json|op-vault-export.*|.*password.*|.*passwd.*|.*secret.*)$/i;
const SECRET_EXTENSION_RE = /\.(pem|key|p12|pfx|kdbx|age|asc|gpg)$/i;
const PUBLIC_KEY_RE = /\.pub$/i;
const HOST_RUNTIME_CONFIG_RE = /(^|[/\\])\.config[/\\]opencode[/\\]opencode\.jsonc?$/i;
const SECRET_PATH_RE = /(^|[/\\])(\.ssh|\.gnupg|\.aws|\.azure|\.config[/\\]gcloud|\.kube|1password|op-vault|password-store)([/\\]|$)/i;
// GH#32526: loose name hints (secret/password/passwd) are routine in framework
// source and docs. Tracked code/doc files carrying only these hints are
// readable; strong credential names and every other extension stay blocked.
const LOOSE_SECRET_BASENAME_RE = /(secret|password|passwd)/i;
const STRONG_SECRET_HINT_RE = /(^\.env|^id_(rsa|dsa|ecdsa|ed25519)|credential|service-account|kubeconfig|op-vault)/i;
const TRACKED_SOURCE_EXTENSION_RE = /\.(sh|mjs|js|ts|py|md)$/i;
const READ_PATH_KEYS = ["filePath", "file_path", "path", "pattern"];
const GIT_ENV_OVERRIDES = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_CEILING_DIRECTORIES"];

function gitEnvironment() {
  const env = { ...process.env, GIT_OPTIONAL_LOCKS: "0", GIT_TERMINAL_PROMPT: "0" };
  for (const name of GIT_ENV_OVERRIDES) delete env[name];
  return env;
}

/**
 * True when a path is a regular, single-link, git-tracked code/doc file whose
 * basename carries only loose secret hints.
 * #aidevops:trust-boundary — tracked status comes from git in the file's own
 * repository, never from path text; symlinks and hard links are refused.
 * @param {string} filePath
 * @returns {boolean}
 */
export function isTrackedSourceWithLooseSecretName(filePath) {
  let tracked = false;
  try {
    const absolute = typeof filePath === "string" && filePath ? resolve(normalize(filePath)) : "";
    tracked = Boolean(absolute) && hasLooseSecretSourceName(absolute) && isGitTrackedRegularFile(absolute);
  } catch {
    tracked = false;
  }
  return tracked;
}

function hasLooseSecretSourceName(absolute) {
  const base = basename(absolute);
  const looseOnly = LOOSE_SECRET_BASENAME_RE.test(base) && !STRONG_SECRET_HINT_RE.test(base);
  const sourceOutsideStores = TRACKED_SOURCE_EXTENSION_RE.test(base) && !SECRET_PATH_RE.test(absolute);
  return looseOnly && sourceOutsideStores;
}

// Throws when git does not list the file; callers treat any error as untracked.
function isGitTrackedRegularFile(absolute) {
  const stat = lstatSync(absolute);
  const directory = realpathSync(dirname(absolute));
  const eligible = stat.isFile() && stat.nlink === 1 && !SECRET_PATH_RE.test(directory);
  if (eligible) {
    execFileSync("git", ["-c", "core.fsmonitor=false", "-C", directory, "ls-files", "--error-unmatch", "--",
      basename(absolute)], { stdio: "ignore", timeout: 3000, env: gitEnvironment() });
  }
  return eligible;
}

/**
 * Check if a tool name is a file read operation.
 * @param {string} tool
 * @returns {boolean}
 */
export function isReadTool(tool) {
  return ["Read", "read", "Glob", "glob", "NotebookRead", "notebook_read"].includes(tool || "");
}

/**
 * Extract a path-like argument from a file-read tool payload.
 * @param {object} args
 * @returns {string}
 */
export function extractReadPath(args = {}) {
  const key = READ_PATH_KEYS.find((name) => args?.[name]);
  return key ? args[key] : "";
}

/**
 * Return a block reason for high-risk secret paths, or empty string when safe.
 * Pure path-text check with no tracked-source exemption; use it where git
 * lookups are unwanted (tree walks, untrusted conversation scopes).
 * @param {string} filePath
 * @returns {string}
 */
export function secretPathBlockReason(filePath) {
  return blockReason(filePath, false);
}

/**
 * Return a block reason for a file read, or empty string when safe. Tracked
 * code/doc files whose basename carries only loose secret hints are allowed.
 * @param {string} filePath
 * @returns {string}
 */
export function secretReadBlockReason(filePath) {
  return blockReason(filePath, true);
}

function blockReason(filePath, allowTrackedSource) {
  const normalized = typeof filePath === "string" && filePath ? normalize(filePath) : "";
  const base = basename(normalized);
  if (!normalized || PUBLIC_KEY_RE.test(base)) return "";
  const exemptSource = () => allowTrackedSource && isTrackedSourceWithLooseSecretName(normalized);
  const rules = [
    ["secret-bearing basename", () => SECRET_BASENAME_RE.test(base) && !exemptSource()],
    ["secret-bearing file extension", () => SECRET_EXTENSION_RE.test(base)],
    ["host runtime config path", () => HOST_RUNTIME_CONFIG_RE.test(normalized)],
    ["credential-store path", () => SECRET_PATH_RE.test(normalized)],
  ];
  const match = rules.find(([, test]) => test());
  return match ? match[0] : "";
}

/**
 * Block OpenCode file-read tools before secret content enters model context.
 * @param {string} tool
 * @param {object} args
 * @param {Function} log
 */
export function checkSecretReadGate(tool, args, log = () => {}) {
  if (!isReadTool(tool)) return;
  const filePath = extractReadPath(args);
  const reason = secretReadBlockReason(filePath);
  if (!reason) return;
  const message = `[secret-read-guard] blocked ${tool} of ${filePath}: ${reason}`;
  log("WARN", message);
  throw new Error(`${message}\n\nUse a non-secret fixture or ask the user to inspect the file locally. Public key files ending .pub are allowed.`);
}
