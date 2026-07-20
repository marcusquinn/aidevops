// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// Secret/private-key pre-read guard for OpenCode file-read tools.

import { basename, normalize } from "path";

const SECRET_BASENAME_RE = /^(id_(rsa|dsa|ecdsa|ed25519)|\.env(\..*)?|credentials(\.sh|\.json|\.ya?ml)?|service-account(\.json)?|kubeconfig|config\.json|op-vault-export.*|.*password.*|.*passwd.*|.*secret.*)$/i;
const SECRET_EXTENSION_RE = /\.(pem|key|p12|pfx|kdbx|age|asc|gpg)$/i;
const PUBLIC_KEY_RE = /\.pub$/i;
const HOST_RUNTIME_CONFIG_RE = /(^|[/\\])\.config[/\\]opencode[/\\]opencode\.jsonc?$/i;
const SECRET_PATH_RE = /(^|[/\\])(\.ssh|\.gnupg|\.aws|\.azure|\.config[/\\]gcloud|\.kube|1password|op-vault|password-store)([/\\]|$)/i;

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
 * @param {string} filePath
 * @returns {string}
 */
export function secretReadBlockReason(filePath) {
  if (!filePath || typeof filePath !== "string") return "";
  const normalized = normalize(filePath);
  const base = basename(normalized);
  if (PUBLIC_KEY_RE.test(base)) return "";
  if (SECRET_BASENAME_RE.test(base)) return "secret-bearing basename";
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
