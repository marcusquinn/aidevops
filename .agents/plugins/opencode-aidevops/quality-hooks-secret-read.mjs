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
  if (!filePath || typeof filePath !== "string") return false;
  const absolute = resolve(normalize(filePath));
  const base = basename(absolute);
  if (!LOOSE_SECRET_BASENAME_RE.test(base) || STRONG_SECRET_HINT_RE.test(base)) return false;
  if (!TRACKED_SOURCE_EXTENSION_RE.test(base) || SECRET_PATH_RE.test(absolute)) return false;
  try {
    const stat = lstatSync(absolute);
    if (!stat.isFile() || stat.nlink !== 1) return false;
    const directory = realpathSync(dirname(absolute));
    if (SECRET_PATH_RE.test(directory)) return false;
    execFileSync("git", ["-c", "core.fsmonitor=false", "-C", directory, "ls-files", "--error-unmatch", "--", base], {
      stdio: "ignore", timeout: 3000, env: gitEnvironment(),
    });
    return true;
  } catch {
    return false;
  }
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
  return args.filePath || args.file_path || args.path || args.pattern || "";
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
  if (!filePath || typeof filePath !== "string") return "";
  const normalized = normalize(filePath);
  const base = basename(normalized);
  if (PUBLIC_KEY_RE.test(base)) return "";
  if (SECRET_BASENAME_RE.test(base)
    && !(allowTrackedSource && isTrackedSourceWithLooseSecretName(normalized))) return "secret-bearing basename";
  if (SECRET_EXTENSION_RE.test(base)) return "secret-bearing file extension";
  if (HOST_RUNTIME_CONFIG_RE.test(normalized)) return "host runtime config path";
  if (SECRET_PATH_RE.test(normalized)) return "credential-store path";
  return "";
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
