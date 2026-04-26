// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Signature gate failure messaging (t2893)
// ---------------------------------------------------------------------------
// Companion module to quality-hooks-signature.mjs. Holds the structured
// failure-reason enum and the throw-message formatter so the main module
// stays under the qlty per-file complexity threshold.
//
// FAIL_REASON values are exported as part of the public surface — tests
// match on these to assert that the right cause is reported for the right
// shape of failure. _formatGateThrowMessage is internal to the gate but
// lives here so the FILE_NOT_FOUND mentorship hint and the standard fixes
// list can evolve without touching the gate logic.

export const FAIL_REASON = {
  FILE_NOT_FOUND: "body-file not found (may be created later in this same bash call)",
  FILE_UNREADABLE: "body-file exists but cannot be read",
  HELPER_MISSING: "gh-signature-helper.sh not found",
  HELPER_FAILED: "gh-signature-helper.sh invocation failed",
  UNPARSEABLE_BODY: "body uses heredoc, process substitution, or command substitution",
  BODY_ARG_QUOTING: "signature contains delimiter quote, cannot safely rewrite --body",
  BODY_ARG_NO_MATCH: "could not parse --body argument shape",
};

const SAME_BASH_CALL_HINT =
  "\n\nLikely cause: the body-file is created in this same bash call. " +
  "This hook runs PRE-execution, so it cannot see files that bash " +
  "hasn't created yet. Two correct fixes:\n" +
  "  a. Split into two bash tool calls: one to create the file, one " +
  "to gh issue/pr comment.\n" +
  "  b. Source shared-gh-wrappers.sh and call gh_issue_comment / " +
  "gh_create_pr / gh_create_issue / gh_pr_comment by name. The shell " +
  "wrapper runs AFTER the file-creation steps in the same bash call, " +
  "so it sees the completed file. The PATH shim at .agents/scripts/gh " +
  "also runs at exec-time as a backstop.";

const STANDARD_FIXES =
  `Standard fixes:\n` +
  `  1. Append to --body directly:\n` +
  `       gh issue comment N --body "...$(gh-signature-helper.sh footer)"\n` +
  `  2. Append to --body-file (two-step pattern):\n` +
  `       gh-signature-helper.sh footer >> "$BODY_FILE"\n` +
  `       gh issue comment N --body-file "$BODY_FILE"\n` +
  `  3. Source the wrapper and call by name:\n` +
  `       source ~/.aidevops/agents/scripts/shared-gh-wrappers.sh\n` +
  `       gh_issue_comment N --body-file "$BODY_FILE"`;

/**
 * Build the throw error message for a structured repair failure (t2893).
 *
 * Adds targeted same-bash-call mentorship for the FILE_NOT_FOUND case —
 * the most common shape that tripped the pre-t2893 generic message.
 * @param {{ reason: string, detail?: string }} failure
 * @param {string} cmdSnippet
 * @returns {string}
 */
export function formatGateThrowMessage(failure, cmdSnippet) {
  const causeBlock = failure.detail
    ? `Specific cause: ${failure.reason} (${failure.detail})`
    : `Specific cause: ${failure.reason}`;
  const sameCallHint = failure.reason === FAIL_REASON.FILE_NOT_FOUND ? SAME_BASH_CALL_HINT : "";
  return (
    `aidevops: gh write command blocked at signature gate (t2685, t2893).\n\n` +
    `${causeBlock}${sameCallHint}\n\n` +
    `${STANDARD_FIXES}\n\n` +
    `Cmd snippet: ${cmdSnippet}\n\n` +
    `Emergency bypass (last resort, breaks audit trail): set\n` +
    `AIDEVOPS_GH_SHIM_DISABLE=1 — but this plugin hook still blocks.`
  );
}
