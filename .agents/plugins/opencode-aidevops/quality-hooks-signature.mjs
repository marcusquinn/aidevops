// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Signature footer gate (GH#12805, t1755, t2685, t2893)
// ---------------------------------------------------------------------------
// Enforces that every `gh issue create|comment` and `gh pr create|comment`
// command posts a body ending with the canonical aidevops signature footer.
// Extracted from quality-hooks.mjs (t2685) to keep the main module below
// the qlty file-complexity ratchet.
//
// Detection tiers:
//   1. cmd contains the literal "gh-signature-helper" → trust the caller,
//      pass through (good-path: they're invoking the helper explicitly).
//   2. cmd contains the canonical HTML marker `<!-- aidevops:sig -->` →
//      a helper-produced footer is already inline. Pass through.
//   3. Footer variable interpolation (`$FOOTER`, `$SIGNATURE`, …) in cmd →
//      likely good-path, log INFO and pass through.
//   4. Machine-protocol comments (DISPATCH_CLAIM, KILL_WORKER, MERGE_SUMMARY)
//      → exempt by design. These are machine-to-machine protocols that
//      workers/pulse parse structurally; adding a footer would corrupt them.
//   5. Otherwise: attempt transparent repair by invoking gh-signature-helper
//      and mutating output.args.command in place. If repair succeeds, the
//      model never sees an error; the command just silently gets the correct
//      footer. If repair fails (heredoc, command substitution in body,
//      unparseable structure), THROW an error that blocks the tool call and
//      educates the next attempt.
//
// Pre-execution race (t2893)
// --------------------------
// This hook runs PRE-bash-execution. When the model writes a single bash
// call that creates a `--body-file` and then immediately posts it (e.g.
// `cp x /tmp/foo.md && gh issue comment --body-file /tmp/foo.md`), the
// readFileSync in _repairBodyFile sees ENOENT — bash hasn't executed the
// file-creation step yet. Prior to t2893 this surfaced as a generic
// "likely heredoc/cmd-sub/quoting" error that didn't name the actual
// cause; the model wasted 3-5 tool calls on the wrong hypothesis.
//
// As of t2893, repair helpers return structured failures
// `{ status: "ok"|"fail", reason?: string, detail?: string, cmd?: string }`,
// the throw site formats the specific cause, and the FILE_NOT_FOUND path
// includes targeted same-bash-call mentorship. The PATH shim at
// .agents/scripts/gh runs at exec-time (after bash creates the file) and
// is the correct enforcement layer for the same-bash-call shape.

import { existsSync, readFileSync, appendFileSync } from "fs";
import { execSync } from "child_process";
import { join } from "path";

export const SIG_MARKER = "<!-- aidevops:sig -->";

/**
 * Structured failure reasons for signature repair (t2893).
 *
 * Each reason names a specific failure mode the repair pipeline can hit.
 * The throw site formats the matching message into the mentoring error so
 * the next attempt knows precisely what to fix instead of guessing across
 * three unrelated causes.
 */
export const FAIL_REASON = {
  FILE_NOT_FOUND: "body-file not found (may be created later in this same bash call)",
  FILE_UNREADABLE: "body-file exists but cannot be read",
  HELPER_MISSING: "gh-signature-helper.sh not found",
  HELPER_FAILED: "gh-signature-helper.sh invocation failed",
  UNPARSEABLE_BODY: "body uses heredoc, process substitution, or command substitution",
  BODY_ARG_QUOTING: "signature contains delimiter quote, cannot safely rewrite --body",
  BODY_ARG_NO_MATCH: "could not parse --body argument shape",
};

/**
 * Strip heredoc body lines from a multi-line command string.
 * Lines inside <<MARKER ... MARKER blocks are removed so that prose
 * inside a heredoc body cannot trigger false-positive gh-write detection
 * (GH#20735 Failure 1).
 *
 * Handles: <<TAG  <<-TAG  <<'TAG'  <<"TAG"
 * Single-heredoc only; nested / multiple heredocs on one line are rare
 * and handled conservatively (opener line is kept, body stripped).
 * @param {string} cmd
 * @returns {string} cmd with heredoc body lines removed
 */
function _stripHeredocBodies(cmd) {
  const lines = cmd.split("\n");
  const result = [];
  let terminator = null;
  for (const line of lines) {
    if (terminator !== null) {
      // Inside a heredoc — check for the terminator (possibly indented for <<-)
      if (line.trim() === terminator) {
        terminator = null;
      }
      // Skip this line regardless (heredoc body or terminator itself)
      continue;
    }
    // Detect a heredoc opener: <<[-] with optional quotes around the tag
    // Use [\w-]+ (not \w+) because bash allows hyphens in heredoc tags
    // e.g. <<EOF-TAG, which \w+ would not match.
    const m = line.match(/<<-?\s*['"]?([\w-]+)['"]?/);
    if (m) {
      terminator = m[1];
    }
    result.push(line);
  }
  return result.join("\n");
}

/**
 * Strip balanced single and double quoted strings from a shell line.
 * Replaces quoted content with empty quotes so that `gh …` tokens embedded
 * inside quoted arguments of other tools (rg, grep, memory-helper.sh …)
 * are invisible to the command-boundary check (GH#20735 Failures 2 & 3).
 *
 * Double quotes are stripped first (with basic escape handling), then
 * single quotes (no escapes inside single quotes in POSIX shell).
 * @param {string} line
 * @returns {string}
 */
function _stripQuotedStrings(line) {
  // Remove double-quoted strings (handles \" inside)
  const withoutDouble = line.replace(/"(?:[^"\\]|\\.)*"/g, '""');
  // Remove single-quoted strings (no escapes possible inside)
  return withoutDouble.replace(/'[^']*'/g, "''");
}

/**
 * Decide whether a given bash command is a gh write that needs sig enforcement.
 *
 * Three-layer false-positive prevention (GH#20735):
 *   1. Heredoc stripping — removes lines inside <<TAG…TAG so prose in a
 *      heredoc body cannot match (Failure 1).
 *   2. Quoted-string stripping — replaces content inside balanced quotes
 *      with empty quotes, hiding `gh …` tokens inside string arguments of
 *      unrelated tools like `rg "gh issue create"` (Failures 2 & 3).
 *   3. Command-boundary anchor — requires `gh` to be at a shell command
 *      start: beginning of the trimmed line, or immediately after one of
 *      ; & | ( ` $( ! — preventing matches mid-argument after plain whitespace.
 *      Also allows optional prefixes (sudo, time, env VAR=val) between the
 *      boundary and `gh` to avoid false negatives on prefixed invocations.
 *
 * @param {string} cmd - Raw bash command string (may be multi-line)
 * @returns {boolean}
 */
export function isGhWriteCommand(cmd) {
  // Layer 3 pattern: gh must start a command segment.
  // Boundaries: start-of-trimmed-line (^), semicolon, ampersand (covers &&),
  // pipe (covers ||), open-paren (subshell / command-sub), backtick, literal $(.
  // Also: ! (bash negation operator — gh still executes, needs sig).
  // After a boundary, allow optional common command prefixes (sudo, time,
  // env with optional VAR=val assignments) before gh to avoid false negatives
  // for patterns like `sudo gh issue create` or `env GH_TOKEN=xxx gh pr create`.
  const ghWritePattern =
    /(^|[;&|(`!]|\$\()\s*(?:(?:sudo|time|env(?:\s+\w+=\S+)*)\s+)*gh\s+(pr\s+(create|comment)|issue\s+(create|comment))\b/;

  // Layer 1: strip heredoc bodies from the full command string first
  const noHeredoc = _stripHeredocBodies(cmd);

  return noHeredoc.split("\n").some((line) => {
    const trimmed = line.trim();
    if (trimmed.startsWith("#")) return false;
    if (/\bgit\s+commit\b/.test(trimmed)) return false;
    // Layer 2: strip quoted strings so embedded gh tokens are invisible
    const unquoted = _stripQuotedStrings(trimmed);
    // Layer 3: require a command-boundary anchor before gh
    return ghWritePattern.test(unquoted);
  });
}

/**
 * Machine-protocol comments that are exempt from sig enforcement.
 * These are structured markers parsed by the pulse, not human-readable
 * messages; adding a footer would corrupt them.
 * @param {string} cmd
 * @returns {boolean}
 */
export function isMachineProtocolCommand(cmd) {
  return /DISPATCH_CLAIM|KILL_WORKER|DISPATCH_ACK|<!-- MERGE_SUMMARY -->/.test(cmd);
}

/**
 * Good-path signal: the command invokes gh-signature-helper directly OR
 * the body content already contains the canonical HTML marker OR a
 * footer-like variable is interpolated in.
 * @param {string} cmd
 * @returns {boolean}
 */
export function hasTrustedSignatureSignal(cmd) {
  if (cmd.includes("gh-signature-helper.sh") || cmd.includes("gh-signature-helper ")) {
    return true;
  }
  if (cmd.includes(SIG_MARKER)) return true;
  // Footer variable interpolation — $FOOTER, ${SIGNATURE}, etc.
  // Requires the cmd to assign the variable upstream; we trust it here
  // because the downstream wrapper/shim will enforce the marker anyway.
  if (/\$\{?\w*(?:footer|FOOTER|signature|SIGNATURE)\w*\}?/i.test(cmd)) return true;
  return false;
}

/**
 * Check if the command uses unparseable body syntax (heredoc, process
 * substitution, or command substitution in the body argument). These forms
 * are too dynamic to rewrite safely and the caller should use the helper
 * explicitly. Returns true if unparseable.
 * @param {string} cmd
 * @returns {boolean}
 */
function _hasUnparseableBody(cmd) {
  // Heredoc / process substitution
  if (/--body(?:-file)?\s*=?\s*(?:<<-?\s*['"]?\w+|<\()/.test(cmd)) return true;
  // Command substitution inside --body value
  const bodyStart = cmd.search(/--body(?:-file)?(?:=|\s)/);
  if (bodyStart === -1) return false;
  const afterBody = cmd.slice(bodyStart);
  return afterBody.includes("$(") || /`[^`]*`/.test(afterBody);
}

/**
 * Generate a signature footer by invoking gh-signature-helper.sh synchronously.
 * Returns `{ status: "ok", sig }` on success or
 * `{ status: "fail", reason: FAIL_REASON.HELPER_FAILED, detail }` on any
 * failure (missing helper, helper error, output missing marker) (t2893).
 * @param {string} helperPath
 * @param {string} bodyValue - body text passed to --body arg of helper
 * @param {Function} log
 * @returns {{ status: "ok", sig: string } | { status: "fail", reason: string, detail: string }}
 */
function _generateSignature(helperPath, bodyValue, log) {
  try {
    const sig = execSync(`"${helperPath}" footer --body ${JSON.stringify(bodyValue)}`, {
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
      shell: "/bin/bash",
    });
    if (!sig || !sig.includes(SIG_MARKER)) {
      log("WARN", "gh-signature-helper output missing marker; refusing to inject");
      return {
        status: "fail",
        reason: FAIL_REASON.HELPER_FAILED,
        detail: "helper output missing canonical marker",
      };
    }
    return { status: "ok", sig };
  } catch (e) {
    log("WARN", `gh-signature-helper invocation failed: ${e.message}`);
    return {
      status: "fail",
      reason: FAIL_REASON.HELPER_FAILED,
      detail: e.message,
    };
  }
}

/**
 * Repair a `--body-file PATH` form by appending the signature footer to the
 * referenced file if missing.
 *
 * Returns `{ status: "ok", cmd }` on success or
 * `{ status: "fail", reason, detail }` on failure. The reason distinguishes
 * FILE_NOT_FOUND (likely the same-bash-call race — bash hasn't created the
 * file yet at the moment this hook runs), FILE_UNREADABLE (other I/O error),
 * or a forwarded HELPER_FAILED from _generateSignature. (t2893)
 * @param {string} cmd
 * @param {string} filePath
 * @param {string} helperPath
 * @param {Function} log
 * @returns {{ status: "ok", cmd: string } | { status: "fail", reason: string, detail: string }}
 */
function _repairBodyFile(cmd, filePath, helperPath, log) {
  try {
    const current = readFileSync(filePath, "utf-8");
    if (current.includes(SIG_MARKER)) return { status: "ok", cmd };
    const sigResult = _generateSignature(helperPath, current, log);
    if (sigResult.status === "fail") return sigResult;
    appendFileSync(filePath, sigResult.sig);
    log("INFO", `Auto-appended signature footer to body-file ${filePath} (t2685)`);
    return { status: "ok", cmd };
  } catch (e) {
    const reason =
      e.code === "ENOENT" ? FAIL_REASON.FILE_NOT_FOUND : FAIL_REASON.FILE_UNREADABLE;
    log("WARN", `Could not repair --body-file ${filePath}: ${e.message} (${reason})`);
    return { status: "fail", reason, detail: `${filePath}: ${e.message}` };
  }
}

/**
 * Match the `--body "value"` / `--body 'value'` / `--body=QUOTED` forms.
 * Returns { match, bodyValue, quote } on the first match, or null.
 *
 * Returning null is "no body arg matched" — distinct from a structured
 * failure object; the caller (`tryRepairSignature`) maps null to
 * `BODY_ARG_NO_MATCH`. (t2893)
 * @param {string} cmd
 * @returns {{ match: RegExpMatchArray, bodyValue: string, quote: string } | null}
 */
function _matchBodyArg(cmd) {
  const patterns = [
    { re: /--body\s+"((?:[^"\\]|\\.)*)"/, quote: '"' },
    { re: /--body\s+'((?:[^'\\]|\\.)*)'/, quote: "'" },
    { re: /--body=(['"])((?:(?!\1).)*)\1/, quote: null },
  ];
  for (const pat of patterns) {
    const m = cmd.match(pat.re);
    if (!m) continue;
    const quote = pat.quote !== null ? pat.quote : m[1];
    const bodyValue = pat.quote !== null ? m[1] : m[2];
    return { match: m, bodyValue, quote };
  }
  return null;
}

/**
 * Repair a `--body "VALUE"` form by rewriting the command with sig-augmented
 * body.
 *
 * Returns `{ status: "ok", cmd }` on success or
 * `{ status: "fail", reason, detail }` when the helper failed or the
 * generated signature contains the same delimiter quote as the body
 * (`BODY_ARG_QUOTING`) which would break shell escaping. (t2893)
 * @param {string} cmd
 * @param {{ match: RegExpMatchArray, bodyValue: string, quote: string }} parsed
 * @param {string} helperPath
 * @param {Function} log
 * @returns {{ status: "ok", cmd: string } | { status: "fail", reason: string, detail: string }}
 */
function _repairBodyArg(cmd, parsed, helperPath, log) {
  const { match, bodyValue, quote } = parsed;
  const sigResult = _generateSignature(helperPath, bodyValue, log);
  if (sigResult.status === "fail") return sigResult;
  const { sig } = sigResult;
  // If sig contains our delimiter quote, rewrite would break escaping —
  // let the block path force explicit helper invocation.
  if (sig.includes(quote)) {
    log("WARN", `Signature contains delimiter quote ${quote}; cannot safely rewrite --body`);
    return {
      status: "fail",
      reason: FAIL_REASON.BODY_ARG_QUOTING,
      detail: `delimiter ${quote}`,
    };
  }
  const fullMatch = match[0];
  const newArg = fullMatch.slice(0, -1) + sig + quote;
  log("INFO", `Auto-appended signature footer to --body arg (t2685)`);
  return { status: "ok", cmd: cmd.replace(fullMatch, newArg) };
}

/**
 * Attempt to append the canonical signature footer to the command's body.
 * Handles `--body "value"`, `--body=value`, and `--body-file path` forms.
 *
 * Returns a structured result so the throw site can name the specific
 * failure cause:
 *   - `{ status: "ok", cmd }` — repair succeeded; cmd may equal input if
 *     the body was already signed.
 *   - `{ status: "fail", reason, detail }` — repair could not be applied;
 *     reason is one of the FAIL_REASON values. (t2893)
 *
 * @param {string} cmd
 * @param {string} scriptsDir
 * @param {Function} log
 * @returns {{ status: "ok", cmd: string } | { status: "fail", reason: string, detail?: string }}
 */
export function tryRepairSignature(cmd, scriptsDir, log) {
  const helperPath = join(scriptsDir, "gh-signature-helper.sh");
  if (!existsSync(helperPath)) {
    log("WARN", `gh-signature-helper.sh not found at ${helperPath}; cannot repair`);
    return { status: "fail", reason: FAIL_REASON.HELPER_MISSING, detail: helperPath };
  }
  if (_hasUnparseableBody(cmd)) {
    log("WARN", "Command has unparseable body (heredoc/command-sub); refusing auto-repair (t2685)");
    return { status: "fail", reason: FAIL_REASON.UNPARSEABLE_BODY };
  }

  // --body-file PATH form: filesystem-side repair.
  const bodyFileMatch = cmd.match(
    /--body-file(?:=(['"]?)([^\s'"]+)\1|\s+(['"]?)([^\s'"]+)\3)/,
  );
  if (bodyFileMatch) {
    const filePath = bodyFileMatch[2] || bodyFileMatch[4];
    return _repairBodyFile(cmd, filePath, helperPath, log);
  }

  // --body VALUE form: command-side repair.
  const parsed = _matchBodyArg(cmd);
  if (!parsed) {
    log("WARN", "Could not parse --body argument; refusing auto-repair");
    return { status: "fail", reason: FAIL_REASON.BODY_ARG_NO_MATCH };
  }
  return _repairBodyArg(cmd, parsed, helperPath, log);
}

/**
 * Build the throw error message for a structured repair failure (t2893).
 *
 * Adds targeted same-bash-call mentorship for the FILE_NOT_FOUND case —
 * the most common shape that tripped the pre-t2893 generic message.
 * @param {{ reason: string, detail?: string }} failure
 * @param {string} cmdSnippet
 * @returns {string}
 */
function _formatGateThrowMessage(failure, cmdSnippet) {
  const causeBlock = failure.detail
    ? `Specific cause: ${failure.reason} (${failure.detail})`
    : `Specific cause: ${failure.reason}`;

  const sameCallHint =
    failure.reason === FAIL_REASON.FILE_NOT_FOUND
      ? "\n\nLikely cause: the body-file is created in this same bash call. " +
        "This hook runs PRE-execution, so it cannot see files that bash " +
        "hasn't created yet. Two correct fixes:\n" +
        "  a. Split into two bash tool calls: one to create the file, one " +
        "to gh issue/pr comment.\n" +
        "  b. Source shared-gh-wrappers.sh and call gh_issue_comment / " +
        "gh_create_pr / gh_create_issue / gh_pr_comment by name. The shell " +
        "wrapper runs AFTER the file-creation steps in the same bash call, " +
        "so it sees the completed file. The PATH shim at .agents/scripts/gh " +
        "also runs at exec-time as a backstop."
      : "";

  return (
    `aidevops: gh write command blocked at signature gate (t2685, t2893).\n\n` +
    `${causeBlock}${sameCallHint}\n\n` +
    `Standard fixes:\n` +
    `  1. Append to --body directly:\n` +
    `       gh issue comment N --body "...$(gh-signature-helper.sh footer)"\n` +
    `  2. Append to --body-file (two-step pattern):\n` +
    `       gh-signature-helper.sh footer >> "$BODY_FILE"\n` +
    `       gh issue comment N --body-file "$BODY_FILE"\n` +
    `  3. Source the wrapper and call by name:\n` +
    `       source ~/.aidevops/agents/scripts/shared-gh-wrappers.sh\n` +
    `       gh_issue_comment N --body-file "$BODY_FILE"\n\n` +
    `Cmd snippet: ${cmdSnippet}\n\n` +
    `Emergency bypass (last resort, breaks audit trail): set\n` +
    `AIDEVOPS_GH_SHIM_DISABLE=1 — but this plugin hook still blocks.`
  );
}

/**
 * Check signature footer gate on gh write commands (GH#12805, t1755, t2685, t2893).
 * @param {string} cmd - Bash command string
 * @param {Function} log - Quality logger function
 * @param {string} scriptsDir - Path to .agents/scripts (for helper invocation)
 * @param {object} output - Tool output (mutated on successful repair)
 */
export function checkSignatureFooterGate(cmd, log, scriptsDir, output) {
  if (!isGhWriteCommand(cmd)) return;
  if (isMachineProtocolCommand(cmd)) return;
  if (hasTrustedSignatureSignal(cmd)) return;

  // Transparent repair — the common case: model pasted a gh write command
  // without thinking about the footer. Mutate the command in place so the
  // user/session gets correct output without an error-retry cycle.
  if (scriptsDir && output && output.args) {
    const result = tryRepairSignature(cmd, scriptsDir, log);
    if (result.status === "ok") {
      if (result.cmd !== cmd) {
        output.args.command = result.cmd;
      }
      return;
    }

    // Repair failed — block the tool call with a mentoring error message
    // that names the SPECIFIC failure cause (t2893). The throw propagates
    // up through opencode's tool execution path and surfaces to the
    // session/model as a tool_error, which means the next attempt can
    // correct itself with knowledge of the actual cause.
    const snippet = cmd.length > 300 ? cmd.substring(0, 300) + "…" : cmd;
    log(
      "ERROR",
      `Blocked gh write missing signature footer (t2685): ${result.reason}` +
        (result.detail ? ` (${result.detail})` : "") +
        ` | cmd: ${snippet}`,
    );
    throw new Error(_formatGateThrowMessage(result, snippet));
  }
}
