// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const PRE_EDIT_GUIDANCE = {
  1: "STOP — you are on main/master branch. Create a worktree first.",
  2: "Create a worktree before proceeding with edits.",
  3: "WARNING — proceed with caution.",
};

/**
 * Format the pre-edit subprocess outcome for the tool response.
 * @param {{code: number|null, stdout: string, stderr: string, timedOut: boolean, error?: Error}} result
 * @param {number} timeoutMs
 * @returns {string}
 */
export function formatPreEditCheckResult(result, timeoutMs) {
  const cmdOutput = (result.stdout + result.stderr).trim();
  let response;
  if (result.timedOut) {
    response = `Pre-edit check TIMED OUT after ${timeoutMs}ms: child process tree terminated before returning\n${cmdOutput}`;
  } else if (result.error) {
    response = `Pre-edit check failed to start: ${result.error.message}\n${cmdOutput}`;
  } else {
    const code = result.code ?? 1;
    const ownershipUnavailable = code === 2
      && cmdOutput.split(/\r?\n/).some((line) => line === "WORKTREE_OWNERSHIP_UNAVAILABLE=true");
    const guidance = ownershipUnavailable
      ? "STOP — retry ownership verification in this worktree; do not create another worktree."
      : (PRE_EDIT_GUIDANCE[code] || "Unknown");
    response = code === 0
      ? `Pre-edit check PASSED (exit 0):\n${cmdOutput}`
      : `Pre-edit check exit ${code}: ${guidance}\n${cmdOutput}`;
  }
  return response;
}
