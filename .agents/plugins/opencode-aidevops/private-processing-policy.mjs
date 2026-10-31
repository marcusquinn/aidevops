// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { activeLocalOnlyPolicy, assertOperatorConfigStat, localFailureCheck, localProvidersOverrideFile,
  LocalOnlyPolicyError } from "./local-only-policy.mjs";
import { appendWorkerBlockerEvent } from "../../scripts/worker-blocker-log.mjs";

// #aidevops:trust-boundary: operator configuration only, snapshotted before
// tools run. Never infer labels from file contents, arguments or model output.
export function loadPrivateProcessingPolicy(env = process.env) {
  const home = env.HOME || homedir();
  const file = resolve(env.XDG_CONFIG_HOME || resolve(home, ".config"), "aidevops/local-only-roots.json");
  // The local-provider override (GH#35723) defines what "local" means for the
  // next launch, so tool writes to it are refused exactly like the roots list.
  const providersFile = localProvidersOverrideFile(env);
  let roots = [];
  let invalid = false;
  try {
    const stat = lstatSync(file);
    assertOperatorConfigStat(stat);
    const config = JSON.parse(readFileSync(file, "utf8"));
    if (!Array.isArray(config.roots) || config.roots.length > 256
      || config.roots.some((root) => typeof root !== "string" || !isAbsolute(root))) throw new Error();
    roots = config.roots.flatMap((root) => [resolve(root), canonicalPath(root)]);
  } catch (error) {
    invalid = error.code !== "ENOENT";
  }
  return Object.freeze({ file, providersFile, invalid, roots: Object.freeze([...new Set(roots)]) });
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
  return tail === "" || (tail !== ".." && !tail.startsWith(`..${sep}`) && !isAbsolute(tail));
}

export function privatePathOverlap(policy, path, cwd, recursive = false) {
  const lexical = resolve(cwd, path);
  const candidates = [lexical, canonicalPath(lexical)];
  return policy.roots.some((root) => candidates.some((candidate) =>
    contains(root, candidate) || (recursive && contains(candidate, root))));
}

export function recordPrivateBlocker(sessionID, check, tool, append = appendWorkerBlockerEvent) {
  // The shared logger uses || for ambient defaults: nonempty constant values
  // suppress those defaults without leaking repo names or request identifiers.
  try {
    return append({ event: "private_processing_blocked", reason: check,
      source: "private-processing-policy", session_key: /^ses_[A-Za-z0-9_-]{1,160}$/.test(sessionID) ? sessionID : "ses_unknown",
      tool, issue_number: null, repo_slug: "none", request_id: "none", detail: "" }, {
      logPath: resolve(homedir(), ".aidevops/.agent-workspace/private-processing-blockers.jsonl"),
      maxBytes: 1024 * 1024,
    }) === true;
  } catch { return false; }
}

export async function notifyLocalFailure({ client, isHeadless, now, append, emitted }, sessionID, error) {
  const check = localFailureCheck(error);
  if (!check) return;
  const timestamp = now();
  if (emitted.has(sessionID) && timestamp - emitted.get(sessionID) < 30000) return;
  emitted.set(sessionID, timestamp);
  const recorded = recordPrivateBlocker(sessionID, check, "model_request", append);
  if (isHeadless()) return;
  try {
    await client.tui.showToast({ body: { title: "Local-only operation stopped",
      message: `${check}: model_request blocked. Local-only binding remains active; no remote fallback is allowed.${recorded ? "" : " Blocker receipt unavailable."}`,
      variant: "error", duration: 15000 } });
  } catch { /* A missing TUI never clears the stop or its receipt. */ }
}

const READ_TOOLS = /^(?:read|grep|glob|list)$/i;
const SHELL_TOOLS = /(?:^|[._-])(?:bash|bounded_operation)$/i;
const MUTATION_TOOLS = /(?:write|edit|apply_patch)$/i;
// A shell cannot be safely classified by substring matching. With classified
// roots, permit only literal, single-command file readers; opaque programs,
// substitutions, pipes and interpreters fail closed rather than hide reads.
const LITERAL_READERS = new Set(["cat", "head", "tail", "wc", "ls", "stat", "pwd"]);
const SHELL_INTERPRETERS = new Set(["sh", "bash", "dash", "ash", "zsh", "ksh", "mksh", "fish", "csh", "tcsh"]);

function literalShellWords(command) {
  if (Array.isArray(command)) return command.every((word) => typeof word === "string") ? command : null;
  const text = String(command || "");
  if (/[\r\n\u0000]/.test(text)) return null;
  const words = [];
  const literal = /[ \t]*(?:"([^"$`\\]*)"|'([^']*)'|([^\s"'\\$`;|&<>*?{}()~]+))(?:[ \t]+|$)/gy;
  let offset = 0;
  while (offset < text.length) {
    literal.lastIndex = offset;
    const match = literal.exec(text);
    if (!match) return null;
    words.push(match[1] ?? match[2] ?? match[3]);
    offset = literal.lastIndex;
  }
  return words;
}

function toolPath(args, cwd) {
  return [args.filePath, args.file_path, args.path, args.directory].find(Boolean) || cwd;
}

// Operator files that define classification or what counts as local.
function protectedConfigFiles(policy) {
  return [policy.file, policy.providersFile].filter(Boolean);
}

// Case-insensitive: default macOS volumes resolve differently-cased names.
function namesProtectedConfig(policy, text) {
  const lower = text.toLowerCase();
  return protectedConfigFiles(policy).some((file) => lower.includes(basename(file).toLowerCase()));
}

// -c, -lc, -ec ..., --command and --command=...
const INTERPRETER_SCRIPT_OPTION = /^(?:-[^-]*c|--command(?:=|$))/;

// Unparseable syntax, or a quoted -c script that is literal to the outer
// parser but not to its interpreter.
function isOpaqueShell(words) {
  return !words || (SHELL_INTERPRETERS.has(basename(String(words[0])))
    && words.slice(1).some((word) => INTERPRETER_SCRIPT_OPTION.test(word)));
}

function assertClassificationMutation(policy, name, args, cwd, deny) {
  if (!MUTATION_TOOLS.test(name)) return;
  // Freeze classification across this launch, and prohibit tool edits to its
  // source. OS ownership is not isolation from code running as the same user.
  const patch = String(args.patchText || args.patch_text || "");
  const mutationPaths = [toolPath(args, cwd), ...[...patch.matchAll(/^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$/gm)].map((match) => match[1])];
  if (protectedConfigFiles(policy).some((file) => mutationPaths.some((target) =>
    contains(resolve(cwd, target), file)
    || contains(canonicalPath(resolve(cwd, target)), canonicalPath(file))))) deny("classification_mutation");
}

function assertShellRead(policy, command, cwd, binding, deny) {
  const text = Array.isArray(command) ? command.join(" ") : String(command || "");
  const words = literalShellWords(command);
  // Resolve literal operands before exemptions: relative and symlink aliases
  // must not bypass the operator-config guard, even in a bound session.
  // Canonicalize each component before processing the next: collapsing a
  // symlink/.. pair lexically would follow a different parent than the OS.
  const targets = words?.slice(1).map((word) => word.split(sep).reduce(
    (parent, component) => canonicalPath(resolve(parent, component)),
    isAbsolute(word) ? sep : canonicalPath(cwd),
  )) || [];
  if (protectedConfigFiles(policy).some((file) => text.includes(file)
    || targets.includes(canonicalPath(file)))) deny("classification_mutation");
  // Opaque shell can hide relative config aliases. Every session runs this hook,
  // so outside a classified unbound session deny it only when it names a
  // protected config file; ordinary pipelines must keep working (GH#36017).
  const exempt = binding.bound || !policy.roots.length;
  if (isOpaqueShell(words) && (!exempt || namesProtectedConfig(policy, text))) deny("unclassifiable_shell_read");
  if (exempt) return;
  // No options: even familiar readers have executable/path-bearing options.
  if (!words?.length || !LITERAL_READERS.has(words[0])
    || words.slice(1).some((word) => word.startsWith("-"))) deny("unclassifiable_shell_read");
  if (privatePathOverlap(policy, cwd, cwd, true)
    || words.slice(1).some((word) => privatePathOverlap(policy, word, cwd, true))) deny("protected_read");
}

export function assertPrivateProcessingRead({ tool, args = {}, repositoryDir = process.cwd(), sessionID = "",
  classification, binding = activeLocalOnlyPolicy(), append }) {
  const policy = classification || loadPrivateProcessingPolicy();
  const name = String(tool || "").split(".").pop();
  const cwd = args.workdir || args.cwd || repositoryDir;
  const deny = (check) => {
    const recorded = recordPrivateBlocker(sessionID, check, READ_TOOLS.test(name) ? name.toLowerCase() : "tool", append);
    throw new LocalOnlyPolicyError(`${check}: protected operation blocked. Relaunch with AIDEVOPS_RUNTIME_POLICY=local-only aidevops opencode. No content was read.${recorded ? "" : " Blocker receipt unavailable."}`);
  };
  assertClassificationMutation(policy, name, args, cwd, deny);
  const shell = SHELL_TOOLS.test(tool);
  if (!READ_TOOLS.test(name) && !shell) return;
  if (shell && args.action && args.action !== "start") return;
  if (policy.invalid) deny("classification_unavailable");
  if (shell) {
    assertShellRead(policy, args.command, cwd, binding, deny);
    return;
  }
  if (!binding.bound && privatePathOverlap(policy, toolPath(args, cwd), cwd, true)) deny("protected_read");
}
