#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared Claim Lifecycle Helpers
# =============================================================================
# Interactive-claim lifecycle helpers shared across merge paths. Extracted from
# pulse-merge.sh (t2429, GH#20067) so that both pulse-merge.sh (deterministic
# merge pass) and full-loop-helper.sh (interactive merge) can release
# interactive claims atomically on PR merge.
#
# Public API:
#   - release_interactive_claim_on_merge <pr_number> <repo_slug> <linked_issue> [pr_labels]
#       Releases the interactive claim stamp + status:in-review label for the
#       linked issue if all guards pass. Best-effort; failures are logged but
#       never propagate.
#
# Guards (all must pass for release to fire):
#   1. linked_issue is non-empty — no issue linked → nothing to release.
#   2. PR carries origin:interactive label — worker PRs manage their own
#      lifecycle via worker-lifecycle-common.sh; do not interfere.
#   3. Claim stamp file exists for the issue — no active interactive session
#      was tracking it; release is a no-op and API calls are unnecessary.
#
# Release failure is logged but does NOT propagate — release is best-effort
# hygiene and must never block the merge completion path.
#
# Usage: source "${SCRIPT_DIR}/shared-claim-lifecycle.sh"
#
# Dependencies:
#   - gh CLI (for pr view label fetch when pr_labels not provided)
#   - interactive-session-helper.sh (for the actual release)
#   - LOGFILE env var (for logging; falls back to /dev/null)
#   - CLAIM_STAMP_DIR env var (optional; defaults to
#     ~/.aidevops/.agent-workspace/interactive-claims)
#   - AGENTS_DIR env var (optional; defaults to ~/.aidevops/agents)
#
# Cross-references: t2413 (original pulse-merge implementation),
#   t2429/GH#20067 (extraction + full-loop-helper parity),
#   AGENTS.md "Interactive issue ownership" → "PR merge auto-release".
# =============================================================================

# Include guard — prevent double-sourcing.
[[ -n "${_SHARED_CLAIM_LIFECYCLE_LOADED:-}" ]] && return 0
_SHARED_CLAIM_LIFECYCLE_LOADED=1

#######################################
# Release the interactive claim for a linked issue after a PR merge.
#
# Called from pulse-merge.sh::_handle_post_merge_actions (deterministic merge)
# and full-loop-helper.sh::cmd_merge (interactive merge) after a successful
# gh pr merge. The function is intentionally best-effort: a failed release is
# logged but never blocks the merge completion path.
#
# Short-circuits (returns 0 silently) when ANY guard fails:
#   1. linked_issue is empty — no issue linked to the merged PR.
#   2. PR does not carry origin:interactive label — worker PRs manage their
#      own lifecycle via worker-lifecycle-common.sh; do not interfere.
#   3. No claim stamp exists for the issue — no active interactive session
#      was tracking it; release is a no-op and API calls are unnecessary.
#
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=pr_labels (optional)
#######################################
release_interactive_claim_on_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_labels="${4:-}"
	local _log="${LOGFILE:-/dev/null}"

	# Guard 1: no linked issue → nothing to release
	[[ -z "$linked_issue" ]] && return 0

	# Guard 2: fetch labels if not provided by caller
	if [[ -z "$pr_labels" ]]; then
		pr_labels=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || pr_labels=""
	fi

	# Guard 3: only fire for origin:interactive PRs — worker PRs handle their
	# own lifecycle, external contributor PRs have no interactive claim stamp
	[[ ",${pr_labels}," == *",origin:interactive,"* ]] || return 0

	# Guard 4: only fire when a claim stamp exists — avoids spurious
	# interactive-session-helper.sh invocations on every origin:interactive merge
	local _stamp_base="${CLAIM_STAMP_DIR:-${HOME}/.aidevops/.agent-workspace/interactive-claims}"
	local _stamp_file="${_stamp_base}/${repo_slug//\//-}-${linked_issue}.json"
	[[ -f "$_stamp_file" ]] || return 0

	echo "[claim-lifecycle] Auto-releasing interactive claim on ${repo_slug}#${linked_issue} (PR #${pr_number} merged) — t2413/t2429" >>"$_log"
	local _isc_helper="${AGENTS_DIR:-${HOME}/.aidevops/agents}/scripts/interactive-session-helper.sh"
	if [[ -x "$_isc_helper" ]]; then
		"$_isc_helper" release "$linked_issue" "$repo_slug" >>"$_log" 2>&1 || \
			echo "[claim-lifecycle] Interactive claim release failed for ${repo_slug}#${linked_issue} — non-fatal (t2413/t2429)" >>"$_log"
	else
		echo "[claim-lifecycle] interactive-session-helper.sh not found/not executable at ${_isc_helper} — skipping release for ${repo_slug}#${linked_issue} (t2413/t2429)" >>"$_log"
	fi
	return 0
}

# Backward-compatible alias: pulse-merge.sh used the underscore-prefixed name.
# Callers may use either form; the underscore-prefixed name is kept so existing
# code (and tests that inline the function) continue to work without changes.
_release_interactive_claim_on_merge() {
	release_interactive_claim_on_merge "$@"
}
