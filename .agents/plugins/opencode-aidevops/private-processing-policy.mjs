// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import { activeLocalOnlyPolicy, LocalOnlyPolicyError } from "./local-only-policy.mjs";
import { appendWorkerBlockerEvent } from "../../scripts/worker-blocker-log.mjs";

// #aidevops:trust-boundary: operator configuration only, snapshotted before
// tools run. Never infer labels from file contents, arguments or model output.
export function loadPrivateProcessingPolicy(env = process.env) {
  const home = env.HOME || homedir();
  const file = resolve(env.XDG_CONFIG_HOME || resolve(home, ".config"), "aidevops/local-only-roots.json");
  let roots = [];
  let invalid = false;
  try {
    const stat = lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o777) !== 0o600
      || (process.getuid && stat.uid !== process.getuid()) || stat.size > 65536) throw new Error();
    const config = JSON.parse(readFileSync(file, "utf8"));
    if (!Array.isArray(config.roots) || config.roots.length > 256
      || config.roots.some((root) => typeof root !== "string" || !isAbsolute(root))) throw new Error();
    roots = config.roots.flatMap((root) => [resolve(root), canonicalPath(root)]);
  } catch (error) {
    invalid = error.code !== "ENOENT";
  }
  return Object.freeze({ file, invalid, roots: Object.freeze([...new Set(roots)]) });
}

function canonicalPath(path) {
  let parent = resolve(path);
  const suffix = [];
  for (;;) {
    try { return resolve(realpathSync(parent), ...suffix); } catch {
      if (dirname(parent) === parent) return resolve(path);
      suffix.unshift(relative(dirname(parent), parent));
      parent = dirname(parent);
    }
  }
}

function contains(root, path) {
  const tail = relative(root, path);
  return tail === "" || (!tail.startsWith("..") && !isAbsolute(tail));
}

export function privatePathOverlap(policy, path, cwd, recursive = false) {
  const lexical = resolve(cwd, path);
  const candidates = [lexical, canonicalPath(lexical)];
  return policy.roots.some((root) => candidates.some((candidate) =>
    contains(root, candidate) || (recursive && contains(candidate, root))));
}

export function recordPrivateBlocker(sessionID, check, tool, append = appendWorkerBlockerEvent) {
  // Explicit empty metadata prevents worker env fields leaking into receipts.
  return append({ event: "private_processing_blocked", reason: check,
    source: "private-processing-policy", session_key: /^ses_[A-Za-z0-9_-]{1,160}$/.test(sessionID) ? sessionID : "",
    tool, issue_number: null, repo_slug: "", request_id: "", detail: "" });
}

const READ_TOOLS = /^(?:read|grep|glob|list)$/i;
const SHELL_TOOLS = /(?:^|[._-])(?:bash|bounded_operation)$/i;
const MUTATION_TOOLS = /(?:write|edit|apply_patch)$/i;
// A shell cannot be safely classified by substring matching. With classified
// roots, permit only literal, single-command file readers; opaque programs,
// substitutions, pipes and interpreters fail closed rather than hide reads.
const LITERAL_READERS = new Set(["cat", "head", "tail", "wc", "ls", "stat", "grep", "rg", "pwd"]);

export function assertPrivateProcessingRead({ tool, args = {}, repositoryDir = process.cwd(), sessionID = "",
  classification, binding = activeLocalOnlyPolicy(), append }) {
  const policy = classification || loadPrivateProcessingPolicy();
  const name = String(tool || "").split(".").pop();
  const cwd = args.workdir || args.cwd || repositoryDir;
  const deny = (check) => {
    recordPrivateBlocker(sessionID, check, READ_TOOLS.test(name) ? name.toLowerCase() : "tool", append);
    throw new LocalOnlyPolicyError(`${check}: protected operation blocked. Relaunch with AIDEVOPS_RUNTIME_POLICY=local-only aidevops opencode. No content was read.`);
  };
  // Freeze classification across this launch, and prohibit tool edits to its
  // source. OS ownership is not isolation from code running as the same user.
  const path = args.filePath || args.file_path || args.path || args.directory || cwd;
  if (MUTATION_TOOLS.test(name) && (contains(resolve(path), policy.file)
    || contains(canonicalPath(path), canonicalPath(policy.file))
    || String(args.patchText || args.patch_text || "").includes(policy.file))) deny("classification_mutation");
  const shell = SHELL_TOOLS.test(tool);
  if (!READ_TOOLS.test(name) && !shell) return;
  if (shell && args.action && args.action !== "start") return;
  if (policy.invalid) deny("classification_unavailable");
  if (shell) {
    const command = args.command;
    const text = Array.isArray(command) ? command.join(" ") : String(command || "");
    if (text.includes(policy.file)) deny("classification_mutation");
    if (binding.bound || !policy.roots.length) return;
    if (/[\n\r$`\\;|&<>*?{}()~]/.test(text)) deny("unclassifiable_shell_read");
    const tokens = Array.isArray(command) ? command : text.match(/"[^"]*"|'[^']*'|[^\s"']+/g) || [];
    const words = tokens.map((token) => String(token).replace(/^(["'])(.*)\1$/, "$2"));
    if (!LITERAL_READERS.has(words[0])) deny("unclassifiable_shell_read");
    if (privatePathOverlap(policy, cwd, cwd, true)
      || words.slice(1).filter((word) => !word.startsWith("-")).some((word) => privatePathOverlap(policy, word, cwd, true))) deny("protected_read");
    return;
  }
  if (!binding.bound && privatePathOverlap(policy, path, cwd, true)) deny("protected_read");
}
