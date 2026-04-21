// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Signature footer gate (GH#12805, t1755, t2685)
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
// The prior implementation only logged a WARN and accepted the literal
// string "aidevops.sh" as sufficient evidence — a failure mode tripped in
// t2685 when the agent composed a human-readable footer inline (which
// happened to contain the word "aidevops.sh") but omitted the runtime,
// version, model, token, and duration metadata that only the helper
// produces. The marker is the reliable, forgery-resistant signal.

import { existsSync, readFileSync, appendFileSync } from "fs";
import { execSync } from "child_process";
import { join } from "path";

export const SIG_MARKER = "<!-- aidevops:sig -->";

/**
 * Decide whether a given bash command is a gh write that needs sig enforcement.
 * @param {string} cmd - Raw bash command string (may be multi-line)
 * @returns {boolean}
 */
export function isGhWriteCommand(cmd) {
  const ghWritePattern = /\bgh\s+(pr\s+(create|comment)|issue\s+(create|comment))\b/;
  return cmd.split("\n").some((line) => {
    const trimmed = line.trim();
    if (trimmed.startsWith("#")) return false;
    if (/\bgit\s+commit\b/.test(trimmed)) return false;
    return ghWritePattern.test(trimmed);
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
 * Returns the footer string on success, or null on any failure (missing
 * helper, helper error, output missing marker).
 * @param {string} helperPath
 * @param {string} bodyValue - body text passed to --body arg of helper
 * @param {Function} log
 * @returns {string | null}
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
      return null;
    }
    return sig;
  } catch (e) {
    log("WARN", `gh-signature-helper invocation failed: ${e.message}`);
    return null;
  }
}

/**
 * Repair a `--body-file PATH` form by appending the signature footer to the
 * referenced file if missing. Returns the unchanged cmd on success, or null
 * on failure (file unreadable, sig generation error).
 * @param {string} cmd
 * @param {string} filePath
 * @param {string} helperPath
 * @param {Function} log
 * @returns {string | null}
 */
function _repairBodyFile(cmd, filePath, helperPath, log) {
  try {
    const current = readFileSync(filePath, "utf-8");
    if (current.includes(SIG_MARKER)) return cmd; // already signed
    const sig = _generateSignature(helperPath, current, log);
    if (sig === null) return null;
    appendFileSync(filePath, sig);
    log("INFO", `Auto-appended signature footer to body-file ${filePath} (t2685)`);
    return cmd;
  } catch (e) {
    log("WARN", `Could not repair --body-file ${filePath}: ${e.message}`);
    return null;
  }
}

/**
 * Match the `--body "value"` / `--body 'value'` / `--body=QUOTED` forms.
 * Returns { match, bodyValue, quote } on the first match, or null.
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
 * body. Returns the repaired command string, or null on failure.
 * @param {string} cmd
 * @param {{ match: RegExpMatchArray, bodyValue: string, quote: string }} parsed
 * @param {string} helperPath
 * @param {Function} log
 * @returns {string | null}
 */
function _repairBodyArg(cmd, parsed, helperPath, log) {
  const { match, bodyValue, quote } = parsed;
  const sig = _generateSignature(helperPath, bodyValue, log);
  if (sig === null) return null;
  // If sig contains our delimiter quote, rewrite would break escaping —
  // let the block path force explicit helper invocation.
  if (sig.includes(quote)) {
    log("WARN", `Signature contains delimiter quote ${quote}; cannot safely rewrite --body`);
    return null;
  }
  const fullMatch = match[0];
  const newArg = fullMatch.slice(0, -1) + sig + quote;
  log("INFO", `Auto-appended signature footer to --body arg (t2685)`);
  return cmd.replace(fullMatch, newArg);
}

/**
 * Attempt to append the canonical signature footer to the command's body.
 * Handles `--body "value"`, `--body=value`, and `--body-file path` forms.
 * Returns the modified command string on success, or null if the command
 * structure is too dynamic to rewrite safely (heredoc body, command
 * substitution inside body, etc.).
 * @param {string} cmd
 * @param {string} scriptsDir
 * @param {Function} log
 * @returns {string | null}
 */
export function tryRepairSignature(cmd, scriptsDir, log) {
  const helperPath = join(scriptsDir, "gh-signature-helper.sh");
  if (!existsSync(helperPath)) {
    log("WARN", `gh-signature-helper.sh not found at ${helperPath}; cannot repair`);
    return null;
  }
  if (_hasUnparseableBody(cmd)) {
    log("WARN", "Command has unparseable body (heredoc/command-sub); refusing auto-repair (t2685)");
    return null;
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
    return null;
  }
  return _repairBodyArg(cmd, parsed, helperPath, log);
}

/**
 * Check signature footer gate on gh write commands (GH#12805, t1755, t2685).
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
    const repaired = tryRepairSignature(cmd, scriptsDir, log);
    if (repaired !== null) {
      if (repaired !== cmd) {
        output.args.command = repaired;
      }
      return;
    }
  }

  // Repair failed or not attempted — block the tool call with a mentoring
  // error message. The throw propagates up through opencode's tool execution
  // path and surfaces to the session/model as a tool_error, which means the
  // next attempt can correct itself.
  const snippet = cmd.length > 300 ? cmd.substring(0, 300) + "…" : cmd;
  log("ERROR", `Blocked gh write missing signature footer (t2685): ${snippet}`);
  throw new Error(
    `aidevops: gh write command missing signature footer (t2685).\n\n` +
      `Fix one of:\n` +
      `  1. Append to --body directly:\n` +
      `       gh issue comment N --body "...$(gh-signature-helper.sh footer)"\n` +
      `  2. Append to --body-file:\n` +
      `       gh-signature-helper.sh footer >> "$BODY_FILE"\n` +
      `       gh issue comment N --body-file "$BODY_FILE"\n` +
      `  3. Call the shell wrapper by name (from a script sourcing\n` +
      `     shared-gh-wrappers.sh): gh_issue_comment / gh_create_issue /\n` +
      `     gh_create_pr / gh_pr_comment.\n\n` +
      `Hook auto-repair could not parse the command — likely a heredoc, ` +
      `command substitution inside the body, or a --body value whose quoting ` +
      `this hook declined to rewrite. See .agents/prompts/build.txt section ` +
      `"8. Signature footer hallucination" for the full rule.\n\n` +
      `Emergency bypass (last resort, breaks audit trail): set ` +
      `AIDEVOPS_GH_SHIM_DISABLE=1 — but the plugin hook still blocks.`,
  );
}
