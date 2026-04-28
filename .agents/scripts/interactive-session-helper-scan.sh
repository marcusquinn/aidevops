#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Interactive Session Scan -- Stale claim detection and PR orphan scanning
# =============================================================================
# Closed-not-merged PR orphan scanning, stamp-based stale claim detection,
# stampless claim discovery, and the scan-stale coordinator.
# Extracted from interactive-session-helper.sh (GH#21320).
#
# Usage: source "${SCRIPT_DIR}/interactive-session-helper-scan.sh"
#
# Dependencies:
#   - shared-constants.sh (_is_process_alive_and_matches, WORKER_PROCESS_PATTERN)
#   - interactive-session-helper-stamp.sh (_isc_list_stampless_interactive_claims)
#   - interactive-session-helper-commands.sh (_isc_cmd_release)
#   - Logging/utility functions from orchestrator (_isc_info, _isc_warn,
#     _isc_gh_reachable, _isc_current_user, _isc_stamp_path)
#   - CLAIM_STAMP_DIR from orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISC_SCAN_LIB_LOADED:-}" ]] && return 0
_ISC_SCAN_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# -----------------------------------------------------------------------------
# Internal helpers: closed-not-merged PR orphan scanning
# -----------------------------------------------------------------------------

# Compute a 14-day cutoff epoch.
# Supports GNU date (Linux) and BSD date (macOS).
_isc_compute_cutoff_epoch() {
	local epoch
	epoch=$(date -d '14 days ago' +%s 2>/dev/null ||
		date -v-14d +%s 2>/dev/null ||
		echo 0)
	printf '%s' "$epoch"
	return 0
}

# Fetch closed-not-merged PRs for a repo within the cutoff window.
# $1: slug (owner/repo), $2: cutoff_epoch
# Outputs: one line per PR, fields joined by \x01 (number|closedAt|title|branch|body).
_isc_fetch_filtered_prs() {
	local slug="$1"
	local cutoff_epoch="$2"
	local prs_raw
	prs_raw=$(gh pr list --repo "$slug" --state closed --limit 50 \
		--json number,title,headRefName,closedAt,mergedAt,body \
		2>/dev/null || echo "[]")
	[[ "$prs_raw" == "[]" || -z "$prs_raw" ]] && return 0
	# shellcheck disable=SC2016  # $cutoff is a jq argjson var, not a shell expansion
	printf '%s' "$prs_raw" | jq -r \
		--argjson cutoff "$cutoff_epoch" \
		'.[] | select(
			.mergedAt == null and
			.closedAt != null and
			(.closedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) >= $cutoff
		) | [(.number | tostring), .closedAt, .title, (.headRefName // ""), .body] | join("\u0001")' \
		2>/dev/null || true
	return 0
}

# Extract issue numbers referenced by closing keywords in a PR body.
# Reads PR body from stdin. Outputs one issue number per line.
# Keywords matched: Resolves, Closes, Fixes, For (case-insensitive).
_isc_extract_pr_linked_issues() {
	grep -oiE '(resolves|closes|fixes|for) #[0-9]+' |
		grep -oE '[0-9]+' 2>/dev/null || true
	return 0
}

# Determine who closed a PR by checking for the deterministic merge pass marker.
# $1: slug (owner/repo), $2: pr_number
# Outputs: "deterministic merge pass (pulse-merge.sh) — HIGH severity" or "unknown".
_isc_get_pr_closed_by() {
	local slug="$1"
	local pr_number="$2"
	local pulse_match
	pulse_match=$(gh api "repos/${slug}/issues/${pr_number}/comments" \
		--jq '[.[] | select(.body | test("deterministic merge pass|pulse-merge"; "i"))] | length' \
		2>/dev/null || echo "0")
	if [[ "${pulse_match:-0}" -gt 0 ]]; then
		printf 'deterministic merge pass (pulse-merge.sh) — HIGH severity'
	else
		printf 'unknown'
	fi
	return 0
}

# Check whether a PR branch still exists on origin.
# $1: slug (owner/repo), $2: pr_branch (may be empty)
# Outputs: "yes" or "no".
_isc_pr_branch_on_origin() {
	local slug="$1"
	local pr_branch="$2"
	if [[ -z "$pr_branch" ]]; then
		printf 'no'
		return 0
	fi
	if gh api "repos/${slug}/git/refs/heads/${pr_branch}" >/dev/null 2>&1; then
		printf 'yes'
	else
		printf 'no'
	fi
	return 0
}

# Print one orphan PR/issue advisory entry to stdout.
# Args: pr_number issue_num pr_title pr_branch branch_exists closed_by pr_closed_at slug
_isc_print_orphan_pr_entry() {
	local pr_number="$1"
	local issue_num="$2"
	local pr_title="$3"
	local pr_branch="$4"
	local branch_exists="$5"
	local closed_by="$6"
	local pr_closed_at="$7"
	local slug="$8"
	printf '  STALE: PR #%s (closed not merged) → issue #%s still OPEN\n' \
		"$pr_number" "$issue_num"
	printf '    Title:      %s\n' "$pr_title"
	printf '    Branch:     %s (still on origin: %s)\n' \
		"${pr_branch:-unknown}" "$branch_exists"
	printf '    Closed by:  %s\n' "$closed_by"
	printf '    Closed at:  %s\n' "$pr_closed_at"
	printf '    Action:     gh pr reopen %s --repo %s\n' "$pr_number" "$slug"
	printf '\n'
	return 0
}

# -----------------------------------------------------------------------------
# Internal: scan closed-not-merged PRs whose linked issue is still open
# -----------------------------------------------------------------------------
# For each pulse-enabled repo in repos.json:
#   1. List PRs closed (not merged) in the last 14 days via gh pr list.
#   2. Extract linked issue numbers from the PR body keywords:
#      Resolves/Closes/Fixes/For #N.
#   3. For each linked issue that is still OPEN, print an advisory.
#
# Does NOT auto-reopen — surfaces for human triage only.
# Exit: 0 always. Prints orphan count to stdout.
_isc_scan_closed_pr_orphans() {
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ ! -f "$repos_json" ]]; then
		printf '0'
		return 0
	fi

	if ! _isc_gh_reachable; then
		_isc_warn "gh not reachable — skipping closed-PR orphan scan"
		printf '0'
		return 0
	fi

	local orphan_count=0
	local cutoff_epoch
	cutoff_epoch=$(_isc_compute_cutoff_epoch)

	local slug
	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue

		local pr_entries
		pr_entries=$(_isc_fetch_filtered_prs "$slug" "$cutoff_epoch")
		[[ -z "$pr_entries" ]] && continue

		local pr_entry
		while IFS= read -r pr_entry; do
			[[ -z "$pr_entry" ]] && continue

			local pr_number pr_closed_at pr_title pr_branch pr_body
			IFS=$'\x01' read -r pr_number pr_closed_at pr_title pr_branch pr_body <<<"$pr_entry"
			[[ -z "$pr_number" ]] && continue

			local issue_nums=()
			local raw_num
			while IFS= read -r raw_num; do
				[[ -z "$raw_num" ]] && continue
				issue_nums+=("$raw_num")
			done < <(printf '%s\n' "$pr_body" | _isc_extract_pr_linked_issues)

			local issue_num
			for issue_num in "${issue_nums[@]+"${issue_nums[@]}"}"; do
				[[ -z "$issue_num" ]] && continue

				local issue_state
				issue_state=$(gh issue view "$issue_num" --repo "$slug" \
					--json state --jq '.state' 2>/dev/null || echo "")
				[[ -z "$issue_state" ]] && continue

				if [[ "$issue_state" == "OPEN" ]]; then
					if [[ $orphan_count -eq 0 ]]; then
						printf '\nClosed-not-merged PRs with still-open linked issues:\n\n'
					fi
					local closed_by branch_exists
					closed_by=$(_isc_get_pr_closed_by "$slug" "$pr_number")
					branch_exists=$(_isc_pr_branch_on_origin "$slug" "$pr_branch")
					_isc_print_orphan_pr_entry \
						"$pr_number" "$issue_num" "$pr_title" "$pr_branch" \
						"$branch_exists" "$closed_by" "$pr_closed_at" "$slug"
					orphan_count=$((orphan_count + 1))
				fi
			done

		done <<<"$pr_entries"

	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' \
		"$repos_json" 2>/dev/null || true)

	printf '%d' "$orphan_count"
	return 0
}

# -----------------------------------------------------------------------------
# _isc_release_claim_by_stamp_path (t2414) — release a claim given a stamp path.
# -----------------------------------------------------------------------------
# Extracts issue+slug from the stamp JSON and delegates to `_isc_cmd_release`
# which handles stamp deletion and label transition atomically. Used by the
# Phase 1 auto-release path in `_isc_scan_dead_stamps_phase`.
# Fail-open: missing stamp, unparseable JSON, or missing fields → warn+skip.
#
# Args:
#   $1 stamp_path — absolute path to the .json stamp file
#
# Exit: 0 always.
_isc_release_claim_by_stamp_path() {
	local stamp_path="$1"

	[[ -f "$stamp_path" ]] || return 0

	local r_issue r_slug
	r_issue=$(jq -r '.issue // empty' "$stamp_path" 2>/dev/null || echo "")
	r_slug=$(jq -r '.slug // empty' "$stamp_path" 2>/dev/null || echo "")

	if [[ -z "$r_issue" || -z "$r_slug" ]]; then
		_isc_warn "_isc_release_claim_by_stamp_path: stamp missing issue/slug — deleting: $stamp_path"
		rm -f "$stamp_path" 2>/dev/null || true
		return 0
	fi

	# Delegate to canonical release flow: stamp deletion + label transition.
	# --unassign is mandatory here: auto-release is the dead-stamp recovery
	# path, the runner that owned the claim is gone, so the self-assignment
	# is meaningless and must clear. Without it, the owner self-assignment
	# persists and keeps dispatch blocked per the t1996 invariant even after
	# the label transitions (GH#21057).
	# _isc_cmd_release is idempotent and fail-open on offline gh.
	_isc_cmd_release --unassign "$r_issue" "$r_slug"
	return 0
}

# scan-stale Phase 1a helper (t2148) — stampless interactive claims.
# -----------------------------------------------------------------------------
# Iterates pulse-enabled repos from repos.json, calls
# _isc_list_stampless_interactive_claims per slug, prints findings to stdout.
# Extracted from _isc_cmd_scan_stale to keep the coordinator under the
# 100-line function cap enforced by the Complexity Analysis CI gate.
#
# Exit: 0 always.
_isc_scan_stampless_phase() {
	printf '\nScanning for stampless interactive claims (origin:interactive + self-assigned + no stamp)...\n'

	local repos_json_1a="${HOME}/.config/aidevops/repos.json"
	local stampless_count=0

	if [[ ! -f "$repos_json_1a" ]] || ! _isc_gh_reachable; then
		printf 'No stampless interactive claims.\n'
		return 0
	fi

	local runner_user_1a
	runner_user_1a=$(_isc_current_user)
	if [[ -z "$runner_user_1a" ]]; then
		printf 'No stampless interactive claims.\n'
		return 0
	fi

	local slug_1a
	while IFS= read -r slug_1a; do
		[[ -z "$slug_1a" ]] && continue

		local row
		while IFS= read -r row; do
			[[ -z "$row" ]] && continue
			local issue_num updated_at
			issue_num=$(printf '%s' "$row" | jq -r '.number' 2>/dev/null)
			updated_at=$(printf '%s' "$row" | jq -r '.updated_at' 2>/dev/null)
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			if [[ $stampless_count -eq 0 ]]; then
				printf '\nStampless interactive claims (origin:interactive + assigned, no stamp):\n\n'
			fi
			printf '  #%s in %s\n' "$issue_num" "$slug_1a"
			printf '    updated:  %s\n' "${updated_at:-unknown}"
			printf '    release:  gh issue edit %s --repo %s --remove-assignee %s\n' \
				"$issue_num" "$slug_1a" "$runner_user_1a"
			printf '\n'
			stampless_count=$((stampless_count + 1))
		done < <(_isc_list_stampless_interactive_claims "$runner_user_1a" "$slug_1a" 2>/dev/null || true)
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' \
		"$repos_json_1a" 2>/dev/null || true)

	if [[ $stampless_count -eq 0 ]]; then
		printf 'No stampless interactive claims.\n'
	else
		printf 'Total: %d stampless claim(s). Unassign to unblock pulse dispatch, or leave for normalize auto-recovery (>24h).\n' "$stampless_count"
	fi

	return 0
}

# scan-stale Phase 1 helper (t2414) — stamp-based stale claim detection.
# -----------------------------------------------------------------------------
# Iterates $CLAIM_STAMP_DIR. For each local-hostname stamp with dead PID AND
# missing worktree: either auto-releases (when auto_release_flag==1) or prints
# a report advisory. Skips stamps with a live PID or existing worktree.
# Extracted from _isc_cmd_scan_stale to keep the coordinator under the
# 100-line function cap (Complexity Analysis CI gate).
#
# Args:
#   $1 auto_release_flag — "1" to auto-release, "0" for report-only
#
# Exit: 0 always.
_isc_scan_dead_stamps_phase() {
	local auto_release_flag="${1:-0}"
	local stale_count=0
	local auto_released=0
	local local_host
	local_host=$(hostname 2>/dev/null || echo "unknown")

	if [[ -d "$CLAIM_STAMP_DIR" ]]; then
		local stamp
		for stamp in "$CLAIM_STAMP_DIR"/*.json; do
			[[ -f "$stamp" ]] || continue
			local issue slug worktree pid hostname
			issue=$(jq -r '.issue // empty' "$stamp" 2>/dev/null || echo "")
			slug=$(jq -r '.slug // empty' "$stamp" 2>/dev/null || echo "")
			worktree=$(jq -r '.worktree_path // empty' "$stamp" 2>/dev/null || echo "")
			pid=$(jq -r '.pid // empty' "$stamp" 2>/dev/null || echo "")
			hostname=$(jq -r '.hostname // empty' "$stamp" 2>/dev/null || echo "")
			[[ -z "$issue" || -z "$slug" ]] && continue
			# Only consider current-hostname stamps — cross-machine stamps
			# can't have their PID verified and must not be surfaced as stale.
			[[ "$hostname" == "$local_host" ]] || continue

			local pid_alive=0
			# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse.
			# Read stored argv hash from stamp for higher precision.
			local stored_hash
			stored_hash=$(jq -r '.owner_argv_hash // empty' "$stamp" 2>/dev/null || echo "")
			if [[ -n "$pid" ]] && _is_process_alive_and_matches "$pid" "${WORKER_PROCESS_PATTERN:-}" "$stored_hash"; then
				pid_alive=1
			fi

			local worktree_exists=0
			[[ -n "$worktree" && -d "$worktree" ]] && worktree_exists=1

			if [[ $pid_alive -eq 0 && $worktree_exists -eq 0 ]]; then
				if [[ "$auto_release_flag" == "1" ]]; then
					_isc_info "[scan-stale] auto-releasing dead stamp: $(basename "$stamp")"
					_isc_release_claim_by_stamp_path "$stamp" >/dev/null 2>&1 || true
					auto_released=$((auto_released + 1))
				else
					[[ $stale_count -eq 0 ]] && printf 'Stale interactive claims (dead PID and missing worktree):\n\n'
					printf '  #%s in %s\n' "$issue" "$slug"
					printf '    worktree: %s (missing)\n' "${worktree:-unknown}"
					printf '    pid:      %s (dead)\n' "${pid:-unknown}"
					printf '    release:  aidevops issue release %s\n' "$issue"
					printf '\n'
					stale_count=$((stale_count + 1))
				fi
			fi
		done
	fi

	if [[ "$auto_release_flag" == "1" ]]; then
		if [[ $auto_released -eq 0 ]]; then
			printf 'No stale interactive claims.\n'
		else
			_isc_info "[scan-stale] Phase 1 auto-released $auto_released stamp(s)."
			printf 'Phase 1: auto-released %d dead stamp(s) (dead PID + missing worktree).\n' "$auto_released"
		fi
	else
		if [[ $stale_count -eq 0 ]]; then
			printf 'No stale interactive claims.\n'
		else
			# shellcheck disable=SC2016  # backticks are literal text, not command substitution
			printf 'Total: %d stale claim(s). Release via `aidevops issue release <N>` or reclaim by `cd`-ing into the worktree.\n' "$stale_count"
		fi
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: scan-stale
# -----------------------------------------------------------------------------
# Three-phase stale detection coordinator. Phase 1 (t2414): auto-releases dead
# stamps (dead PID + missing worktree) when running in an interactive TTY.
# Phase 1a: report-only (stampless origin:interactive claims).
# Phase 2: report-only (closed-not-merged PR orphans).
#
# Arguments:
#   [--auto-release]    — force Phase 1 auto-release on (overrides env/TTY)
#   [--no-auto-release] — force Phase 1 auto-release off (overrides env/TTY)
#
# Env: AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0|1 — overrides TTY detection.
#
# Exit: 0 always.
_isc_cmd_scan_stale() {
	# --- auto-release flag resolution (t2414) ---
	# Priority: explicit flag > env var > TTY detection > default OFF.
	local auto_release_flag=""
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--auto-release) auto_release_flag=1 ; shift ;;
		--no-auto-release) auto_release_flag=0 ; shift ;;
		*) shift ;;
		esac
	done
	if [[ -z "$auto_release_flag" && -n "${AIDEVOPS_SCAN_STALE_AUTO_RELEASE:-}" ]]; then
		auto_release_flag="${AIDEVOPS_SCAN_STALE_AUTO_RELEASE}"
	fi
	if [[ -z "$auto_release_flag" ]]; then
		[[ -t 0 && -t 1 ]] && auto_release_flag=1 || auto_release_flag=0
	fi

	# --- Phase 1: stamp-based stale claim detection (extracted for line-cap) ---
	_isc_scan_dead_stamps_phase "$auto_release_flag"

	# --- Phase 1a: stampless origin:interactive claims (t2148) ---
	_isc_scan_stampless_phase

	# --- Phase 2: closed-not-merged PR orphan detection (cross-repo) ---
	printf '\nScanning for closed-not-merged PRs with still-open linked issues...\n'
	local orphan_count
	orphan_count=$(_isc_scan_closed_pr_orphans 2>/dev/null || echo "0")
	if [[ "$orphan_count" -eq 0 ]]; then
		printf 'No closed-not-merged PR orphans found.\n'
	else
		printf 'Total: %d closed-not-merged PR orphan(s). Review the above — do NOT auto-reopen without verifying the close was unintentional.\n' "$orphan_count"
	fi
	return 0
}
